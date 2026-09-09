--- Core recording engine.
---
--- Deliberately mirrors the structure of the VS Code recorder's
--- `EditorRecordingManager` so the three recorders can be reasoned about
--- together: buffer changes are queued, batched by document, flushed after an
--- idle interval, and written as gzip members next to the source file.
---
--- The Neovim-specific part is change capture. `nvim_buf_attach`'s `on_bytes`
--- reports *where* a change happened and how many bytes it replaced, but not
--- what was replaced, so the recorder keeps a shadow copy of every tracked
--- buffer. The shadow supplies `oldFragment`; the buffer itself supplies
--- `newFragment`. When the shadow and the buffer disagree the recorder gives up
--- on deltas for that change and emits a full snapshot instead, which is the
--- escape hatch the shared schema documents.

local config = require('code-recorder.config')
local log = require('code-recorder.log')
local writer = require('code-recorder.writer')

local api = vim.api

local M = {}

--- Recording state. Everything here is reset by `start`.
local state = {
    active = false,
    roots = {},
    queue = {},
    current_batch = {},
    -- docid -> full buffer text as the recorder believes it to be
    shadows = {},
    -- docid -> queued initial snapshots, held until a real edit arrives
    deferred = {},
    -- docid -> true once the document has received a real edit this session
    edited = {},
    -- output path -> true, for documents actually being recorded
    active_paths = {},
    -- bufnr -> descriptor
    attached = {},
    timer = nil,
    augroup = nil,
    processing = false,
}

--- Fired on state changes so the statusline and tests can react.
M.callbacks = {
    on_state_changed = {},
    on_document_recorded = {},
}

local function emit(event, ...)
    for _, callback in ipairs(M.callbacks[event]) do
        pcall(callback, ...)
    end
end

--------------------------------------------------------------------------------
-- Buffer helpers
--------------------------------------------------------------------------------

--- Reconstructs a buffer's text in the byte space `on_bytes` reports offsets in.
---
--- Two normalisations fall out of Neovim's buffer model, and both are
--- deliberate:
---
---  * Buffer lines never carry a `\r`, so a CRLF file records as if it used LF.
---  * The trailing newline is always present, even when 'noeol' means it will not
---    be written to disk. Neovim counts it in every byte offset it reports
---    (`nvim_buf_get_offset` includes it regardless of 'eol'), so the shadow must
---    include it or every offset after the first edit would be wrong.
---
--- @param buf integer
--- @return string
local function buffer_text(buf)
    return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n'
end

--- Converts a byte offset into a codepoint offset.
---
--- `on_bytes` speaks bytes, but `recan` splices fragments into a Python `str`,
--- which is indexed by codepoint. The two agree for ASCII, so the common case
--- costs one scan and nothing else.
--- @param text string
--- @param byte_offset integer
--- @return integer
local function char_offset(text, byte_offset)
    if byte_offset <= 0 then
        return 0
    end
    if not text:find('[\128-\255]') then
        return byte_offset
    end
    local _, count = text:sub(1, byte_offset):gsub('[^\128-\191]', '')
    return count
end

M._char_offset = char_offset
M._buffer_text = buffer_text

--------------------------------------------------------------------------------
-- Eligibility
--------------------------------------------------------------------------------

local function normalise(path)
    return (path:gsub('\\', '/'))
end

--- Reports whether `path` lives under one of the recorded workspace roots.
local function within_roots(path)
    if #state.roots == 0 then
        return false
    end
    local target = normalise(path)
    for _, root in ipairs(state.roots) do
        local prefix = normalise(root):gsub('/$', '')
        if target == prefix or target:sub(1, #prefix + 1) == prefix .. '/' then
            return true
        end
    end
    return false
end

--- Reports whether `path` has a tracked extension.
local function has_tracked_extension(path)
    local ext = path:match('(%.[^./\\]+)$')
    if not ext then
        return false
    end
    for _, tracked in ipairs(config.get().tracked_extensions) do
        if ext == tracked then
            return true
        end
    end
    return false
end

--- Reports whether a buffer should be recorded.
--- @param buf integer
--- @return boolean
local function should_record(buf)
    if not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then
        return false
    end
    if vim.bo[buf].buftype ~= '' then
        return false
    end

    local name = api.nvim_buf_get_name(buf)
    if name == '' then
        return false
    end
    if writer.is_recording_file(name) then
        return false
    end
    if not has_tracked_extension(name) then
        return false
    end
    return within_roots(name)
end

M._should_record = should_record

--- Builds the descriptor used for every event from a buffer.
local function descriptor_for(buf)
    local name = api.nvim_buf_get_name(buf)
    return {
        id = name,
        display = name,
        output = writer.recording_path(name),
    }
end

--------------------------------------------------------------------------------
-- Queueing
--------------------------------------------------------------------------------

local function schedule_flush()
    if not state.timer then
        return
    end
    state.timer:stop()
    state.timer:start(
        config.get().batch_idle_ms,
        0,
        vim.schedule_wrap(function()
            M._process_queue()
        end)
    )
end

--- Queues a full-document snapshot when the buffer differs from the shadow.
---
--- `kind` is `initialSnapshot` for content seeded on open or on start — held in
--- memory until a real edit arrives — and `recoverySnapshot` when the snapshot is
--- itself the product of a change we could not serialise incrementally. Recovery
--- snapshots count as real edits and are written immediately.
---
--- Passing nil picks for you: once a document has been edited there is no such
--- thing as an initial snapshot for it any more, so any later content change we
--- could not follow is a recovery.
--- @param buf integer
--- @param kind string|nil
local function record_snapshot_if_changed(buf, kind)
    if not should_record(buf) then
        return
    end

    local descriptor = descriptor_for(buf)
    kind = kind or (state.edited[descriptor.id] and 'recoverySnapshot' or 'initialSnapshot')

    local text = buffer_text(buf)
    if state.shadows[descriptor.id] == text then
        return
    end

    state.shadows[descriptor.id] = text
    state.queue[#state.queue + 1] = {
        kind = 'change',
        change_kind = kind,
        timestamp = writer.timestamp(),
        descriptor = descriptor,
        offset = 0,
        old_fragment = text,
        new_fragment = text,
    }
    schedule_flush()
end

--- Queues a status event for every actively recording document.
--- @param status_type string
--- @param fields table[]|nil Ordered `{ key, value }` pairs.
function M.queue_status_event(status_type, fields)
    if not state.active then
        return
    end
    state.queue[#state.queue + 1] = {
        kind = 'status',
        timestamp = writer.timestamp(),
        status_type = status_type,
        fields = fields or {},
    }
    schedule_flush()
end

--------------------------------------------------------------------------------
-- Change capture
--------------------------------------------------------------------------------

--- `nvim_buf_attach` byte callback.
---
--- Runs in a fast event context, so it does nothing beyond reading the buffer,
--- splicing the shadow, and appending to the queue.
local function on_bytes(_, buf, _, _, _, start_byte, _, _, old_end_byte, _, _, new_end_byte)
    if not state.active then
        return true
    end

    local descriptor = state.attached[buf]
    if not descriptor then
        return true
    end

    local function recover()
        state.shadows[descriptor.id] = nil
        vim.schedule(function()
            record_snapshot_if_changed(buf, 'recoverySnapshot')
        end)
    end

    local shadow = state.shadows[descriptor.id]
    if not shadow then
        -- No baseline to diff against, so the post-change buffer is all we can
        -- honestly report. This is a real edit, not a deferrable snapshot.
        recover()
        return
    end

    local ok, current = pcall(buffer_text, buf)
    if not ok then
        recover()
        return
    end

    -- Both fragments are sliced out of full document text rather than derived
    -- from the row/column arguments. A change that ends on the buffer's implicit
    -- final newline is not addressable by `nvim_buf_get_text`, and byte slicing
    -- sidesteps that entirely.
    local old_fragment = shadow:sub(start_byte + 1, start_byte + old_end_byte)
    local new_fragment = current:sub(start_byte + 1, start_byte + new_end_byte)
    local updated = shadow:sub(1, start_byte)
        .. new_fragment
        .. shadow:sub(start_byte + old_end_byte + 1)

    -- If replaying our own delta does not reproduce the buffer, the delta is not
    -- trustworthy and the schema's snapshot escape hatch applies.
    if updated ~= current then
        recover()
        return
    end

    state.queue[#state.queue + 1] = {
        kind = 'change',
        change_kind = 'delta',
        timestamp = writer.timestamp(),
        descriptor = descriptor,
        offset = char_offset(shadow, start_byte),
        old_fragment = old_fragment,
        new_fragment = new_fragment,
    }
    state.shadows[descriptor.id] = updated

    emit('on_document_recorded')
    schedule_flush()
end

--- Attaches to a buffer and seeds its shadow, if it is eligible and not already
--- attached.
--- @param buf integer
local function attach(buf)
    if state.attached[buf] or not should_record(buf) then
        return
    end

    local descriptor = descriptor_for(buf)
    state.attached[buf] = descriptor

    local ok = api.nvim_buf_attach(buf, false, {
        on_bytes = on_bytes,
        on_reload = function(_, reloaded)
            vim.schedule(function()
                local reloaded_descriptor = state.attached[reloaded]
                if not reloaded_descriptor then
                    return
                end
                state.shadows[reloaded_descriptor.id] = nil
                record_snapshot_if_changed(reloaded)
            end)
        end,
        on_detach = function(_, detached)
            state.attached[detached] = nil
        end,
    })

    if not ok then
        state.attached[buf] = nil
        log.warn('Could not attach to ' .. descriptor.display)
        return
    end

    log.debug('Attached to ' .. descriptor.display)
    record_snapshot_if_changed(buf, 'initialSnapshot')
end

M._attach = attach

--------------------------------------------------------------------------------
-- Queue processing
--------------------------------------------------------------------------------

local function encode_change(change)
    return writer.encode_edit({
        timestamp = change.timestamp,
        document = change.descriptor.display,
        offset = change.offset,
        old_fragment = change.old_fragment,
        new_fragment = change.new_fragment,
    })
end

--- Writes a batch of changes for one document.
local function write_changes(descriptor, changes)
    if #changes == 0 then
        return
    end

    local lines = {}
    for _, change in ipairs(changes) do
        lines[#lines + 1] = encode_change(change)
    end

    local ok, err = writer.append(descriptor.output, lines)
    if not ok then
        log.error(
            string.format('Failed to write batch for %s: %s', descriptor.display, tostring(err))
        )
    end
end

--- Writes the current batch, or holds it back if its document has not yet been
--- truly edited so that a merely-open file never produces a recording.
local function flush_or_defer_batch()
    if #state.current_batch == 0 then
        return
    end

    local descriptor = state.current_batch[1].descriptor
    local id = descriptor.id

    if state.edited[id] then
        write_changes(descriptor, state.current_batch)
    else
        local pending = state.deferred[id] or {}
        for _, change in ipairs(state.current_batch) do
            pending[#pending + 1] = change
        end
        state.deferred[id] = pending
        log.debug(
            'Deferring initial snapshot for ' .. descriptor.display .. ' until a real edit arrives'
        )
    end

    state.current_batch = {}
end

local function write_status_event(item)
    local line = writer.encode_status(item.status_type, item.timestamp, item.fields)
    if vim.tbl_isempty(state.active_paths) then
        log.debug('No active recordings for status event: ' .. line)
        return
    end
    for path in pairs(state.active_paths) do
        local ok, err = writer.append(path, { line })
        if not ok then
            log.error(string.format('Failed to write status event to %s: %s', path, tostring(err)))
        end
    end
end

--- Promotes a document from "merely open" to "actively recording" on its first
--- real edit: registers its output path and writes any snapshot held in memory
--- so the recording opens with the pre-edit document state.
local function promote_if_first_edit(item)
    if item.change_kind == 'initialSnapshot' then
        return
    end

    local id = item.descriptor.id
    if state.edited[id] then
        return
    end

    state.edited[id] = true
    state.active_paths[item.descriptor.output] = true

    local pending = state.deferred[id]
    if pending then
        state.deferred[id] = nil
        write_changes(item.descriptor, pending)
    end
end

--- Drains the queue into per-document batches and writes them out.
function M._process_queue()
    if state.processing then
        return
    end
    state.processing = true

    local ok, err = pcall(function()
        while #state.queue > 0 do
            local item = table.remove(state.queue, 1)

            if item.kind == 'change' then
                if
                    #state.current_batch > 0
                    and state.current_batch[1].descriptor.id ~= item.descriptor.id
                then
                    flush_or_defer_batch()
                end
                promote_if_first_edit(item)
                state.current_batch[#state.current_batch + 1] = item
            elseif item.kind == 'status' then
                flush_or_defer_batch()
                write_status_event(item)
            elseif item.kind == 'stop' then
                flush_or_defer_batch()
            end
        end

        flush_or_defer_batch()
    end)

    state.processing = false

    if not ok then
        log.error('Queue processing failed: ' .. tostring(err))
    end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

--- Resolves the workspace roots recording is confined to.
---
--- Every root is expanded to an absolute path. Buffer names always are, so a
--- root left relative (`'src'`) or written with a `~` would match nothing and the
--- recorder would silently record nothing at all — the worst way for this tool to
--- fail, because it looks like it is working.
local function collect_roots()
    local configured = config.get().roots
    local roots = (configured and #configured > 0) and configured or { vim.fn.getcwd() }

    local resolved = {}
    for _, root in ipairs(roots) do
        resolved[#resolved + 1] = vim.fn.fnamemodify(root, ':p')
    end
    return resolved
end

local function create_autocmds()
    local group = api.nvim_create_augroup('CodeRecorderSession', { clear = true })
    state.augroup = group

    api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile', 'BufEnter', 'BufWinEnter' }, {
        group = group,
        callback = function(args)
            if state.attached[args.buf] then
                -- Already tracked; re-snapshot only if something changed the
                -- buffer behind our back.
                record_snapshot_if_changed(args.buf)
            else
                attach(args.buf) -- seeds the snapshot itself
            end
        end,
    })

    api.nvim_create_autocmd('FocusGained', {
        group = group,
        callback = function()
            M.queue_status_event('focusStatus', { { 'focused', true } })
        end,
    })

    api.nvim_create_autocmd('FocusLost', {
        group = group,
        callback = function()
            M.queue_status_event('focusStatus', { { 'focused', false } })
        end,
    })

    api.nvim_create_autocmd('DirChanged', {
        group = group,
        callback = function()
            M.refresh_roots()
        end,
    })

    api.nvim_create_autocmd('VimLeavePre', {
        group = group,
        callback = function()
            M.stop()
        end,
    })
end

--- Returns whether recording is currently active.
--- @return boolean
function M.is_recording()
    return state.active
end

--- Starts recording buffer changes under the workspace roots.
function M.start()
    if state.active then
        log.debug('Recording already active; ignoring start request')
        return
    end

    state.active = true
    state.roots = collect_roots()
    state.queue = {}
    state.current_batch = {}
    state.shadows = {}
    state.deferred = {}
    state.edited = {}
    state.active_paths = {}
    state.attached = {}
    state.timer = vim.uv.new_timer()

    log.info(
        string.format(
            'Recording under %d root(s): %s',
            #state.roots,
            table.concat(state.roots, ', ')
        )
    )

    create_autocmds()

    for _, buf in ipairs(api.nvim_list_bufs()) do
        attach(buf)
    end

    emit('on_state_changed', true)
    log.info('Editor recording started')

    if config.get().notify then
        vim.notify('Code Recorder: recording started', vim.log.levels.INFO)
    end
end

--- Stops recording and flushes pending events.
function M.stop()
    if not state.active then
        log.debug('Recording not active; ignoring stop request')
        return
    end

    state.queue[#state.queue + 1] = { kind = 'stop' }
    M._process_queue()

    if state.timer then
        state.timer:stop()
        if not state.timer:is_closing() then
            state.timer:close()
        end
        state.timer = nil
    end

    -- Snapshots still held in memory belong to files that were opened but never
    -- edited, so they are discarded rather than written.
    local deferred_count = vim.tbl_count(state.deferred)
    if deferred_count > 0 then
        log.debug(string.format('Discarding %d initial snapshot(s) with no edits', deferred_count))
    end

    if state.augroup then
        api.nvim_del_augroup_by_id(state.augroup)
        state.augroup = nil
    end

    state.active = false
    state.roots = {}
    state.queue = {}
    state.current_batch = {}
    state.shadows = {}
    state.deferred = {}
    state.edited = {}
    state.active_paths = {}
    state.attached = {}

    emit('on_state_changed', false)
    log.info('Editor recording stopped')

    if config.get().notify then
        vim.notify('Code Recorder: recording stopped', vim.log.levels.INFO)
    end
end

--- Toggles recording.
function M.toggle()
    if state.active then
        M.stop()
    else
        M.start()
    end
end

--- Re-resolves workspace roots after the working directory changes.
function M.refresh_roots()
    if not state.active then
        return
    end
    local previous = #state.roots
    state.roots = collect_roots()
    log.debug(string.format('Refreshed workspace roots: %d -> %d', previous, #state.roots))

    for _, buf in ipairs(api.nvim_list_bufs()) do
        attach(buf)
    end
end

--- Flushes any pending events immediately. Mostly useful for tests and for
--- `:CodeRecorderFlush`.
function M.flush()
    if state.timer then
        state.timer:stop()
    end
    M._process_queue()
end

--- Returns a snapshot of recorder state for the statusline and `:CodeRecorderStatus`.
--- @return table
function M.status()
    local documents = {}
    for id in pairs(state.edited) do
        documents[#documents + 1] = id
    end
    table.sort(documents)

    return {
        recording = state.active,
        roots = vim.deepcopy(state.roots),
        attached = vim.tbl_count(state.attached),
        documents = documents,
        pending = #state.queue + #state.current_batch,
    }
end

M._state = state

return M
