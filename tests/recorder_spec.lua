local T = _G.TEST
local config = require('code-recorder.config')
local recorder = require('code-recorder.recorder')
local writer = require('code-recorder.writer')

--------------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------------

local captured = {}
local real_append = writer.append

--- Intercepts writes so tests assert on JSON lines rather than gzip bytes.
local function intercept()
    captured = {}
    writer.append = function(path, lines)
        local bucket = captured[path] or {}
        for _, line in ipairs(lines) do
            bucket[#bucket + 1] = line
        end
        captured[path] = bucket
        return true
    end
end

local function restore()
    writer.append = real_append
end

--- Starts a recording session rooted at a fresh temp directory.
--- @return string dir
local function session()
    if recorder.is_recording() then
        recorder.stop()
    end
    local dir = T.temp_dir()
    config.setup({ roots = { dir }, notify = false, resume_prompt = false })
    intercept()
    recorder.start()
    return dir
end

local function teardown()
    if recorder.is_recording() then
        recorder.stop()
    end
    restore()
    config.reset()
end

--- Writes `contents` to `dir/name` and opens it.
--- @return integer buf
--- @return string path
local function open_file(dir, name, contents)
    local path = dir .. '/' .. name
    local handle = assert(io.open(path, 'wb'))
    handle:write(contents)
    handle:close()
    vim.cmd.edit(vim.fn.fnameescape(path))
    return vim.api.nvim_get_current_buf(), path
end

local function lines_for(path)
    return captured[writer.recording_path(path)] or {}
end

local function events_for(path)
    local out = {}
    for _, line in ipairs(lines_for(path)) do
        out[#out + 1] = vim.json.decode(line)
    end
    return out
end

--------------------------------------------------------------------------------
-- Replay, mirroring recan's splice
--------------------------------------------------------------------------------

--- Byte index of the `char_off`-th codepoint boundary.
local function byte_index(s, char_off)
    if char_off <= 0 then
        return 0
    end
    local n, i = 0, 1
    while i <= #s do
        local b = s:byte(i)
        local size = (b < 0x80 and 1) or (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4
        n = n + 1
        i = i + size
        if n == char_off then
            return i - 1
        end
    end
    return #s
end

--- Applies one edit the way `recan.utils.splice` does: offsets are codepoints.
local function splice(doc, offset, old, new)
    local start = byte_index(doc, offset)
    return doc:sub(1, start) .. new .. doc:sub(start + #old + 1)
end

--- Replays a recording into the document text it describes.
local function replay(events)
    local doc = ''
    for _, event in ipairs(events) do
        if event.type == 'edit' then
            if event.offset == 0 and event.oldFragment == event.newFragment then
                doc = event.newFragment -- snapshot
            else
                doc = splice(doc, event.offset, event.oldFragment, event.newFragment)
            end
        end
    end
    return doc
end

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

T.describe('recorder: deferred recording', function()
    T.it('writes nothing for a file that is only opened', function()
        local dir = session()
        local _, path = open_file(dir, 'untouched.py', 'print("hi")\n')
        recorder.flush()
        T.assert_same({}, lines_for(path))
        teardown()
    end)

    T.it('discards the buffered snapshot on stop when no edit arrives', function()
        local dir = session()
        local _, path = open_file(dir, 'untouched.py', 'print("hi")\n')
        recorder.stop()
        T.assert_same({}, lines_for(path))
        restore()
        config.reset()
    end)

    T.it('writes the pre-edit snapshot ahead of the first delta', function()
        local dir = session()
        local buf, path = open_file(dir, 'prog.py', 'a = 1\n')
        vim.api.nvim_buf_set_text(buf, 0, 5, 0, 5, { '0' })
        recorder.flush()

        local events = events_for(path)
        T.assert_true(#events >= 2, 'expected a snapshot plus a delta')
        T.assert_equal(0, events[1].offset)
        T.assert_equal(events[1].oldFragment, events[1].newFragment)
        T.assert_equal('a = 1\n', events[1].newFragment)
        T.assert_equal('0', events[2].newFragment)
        T.assert_equal('', events[2].oldFragment)
        teardown()
    end)
end)

T.describe('recorder: event shape', function()
    T.it('stamps editor and recorderVersion on every event', function()
        local dir = session()
        local buf, path = open_file(dir, 'prog.py', 'x\n')
        vim.api.nvim_buf_set_text(buf, 0, 1, 0, 1, { 'y' })
        recorder.flush()

        for _, event in ipairs(events_for(path)) do
            T.assert_equal('neovim', event.editor)
            T.assert_equal(require('code-recorder.version'), event.recorderVersion)
            T.assert_match('^%d%d%d%d%-%d%d%-%d%dT', event.timestamp)
        end
        teardown()
    end)

    T.it('records the absolute document path', function()
        local dir = session()
        local buf, path = open_file(dir, 'prog.py', 'x\n')
        vim.api.nvim_buf_set_text(buf, 0, 1, 0, 1, { 'y' })
        recorder.flush()

        local document = events_for(path)[1].document
        T.assert_equal(vim.fs.normalize(path), vim.fs.normalize(document))
        teardown()
    end)
end)

T.describe('recorder: deltas', function()
    T.it('captures an insertion', function()
        local dir = session()
        local buf, path = open_file(dir, 'prog.py', 'ab\n')
        vim.api.nvim_buf_set_text(buf, 0, 1, 0, 1, { 'X' })
        recorder.flush()

        local edit = events_for(path)[2]
        T.assert_equal(1, edit.offset)
        T.assert_equal('', edit.oldFragment)
        T.assert_equal('X', edit.newFragment)
        teardown()
    end)

    T.it('captures a deletion', function()
        local dir = session()
        local buf, path = open_file(dir, 'prog.py', 'abcd\n')
        vim.api.nvim_buf_set_text(buf, 0, 1, 0, 3, {})
        recorder.flush()

        local edit = events_for(path)[2]
        T.assert_equal(1, edit.offset)
        T.assert_equal('bc', edit.oldFragment)
        T.assert_equal('', edit.newFragment)
        teardown()
    end)

    T.it('captures a replacement spanning lines', function()
        local dir = session()
        local buf, path = open_file(dir, 'prog.py', 'one\ntwo\nthree\n')
        vim.api.nvim_buf_set_lines(buf, 0, 2, false, { 'ONE' })
        recorder.flush()

        local edit = events_for(path)[2]
        T.assert_equal(0, edit.offset)
        T.assert_equal('one\ntwo\n', edit.oldFragment)
        T.assert_equal('ONE\n', edit.newFragment)
        teardown()
    end)

    T.it('captures an edit that lands on the final newline', function()
        local dir = session()
        local buf, path = open_file(dir, 'prog.py', 'tail\n')
        vim.api.nvim_buf_set_lines(buf, 1, 1, false, { 'appended' })
        recorder.flush()

        T.assert_equal('tail\nappended\n', replay(events_for(path)))
        teardown()
    end)
end)

T.describe('recorder: multibyte offsets', function()
    T.it('reports codepoint offsets, not byte offsets', function()
        local dir = session()
        -- "é" is two bytes; an edit after it sits at codepoint offset 2.
        local buf, path = open_file(dir, 'prog.py', '#é\n')
        vim.api.nvim_buf_set_text(buf, 0, 3, 0, 3, { '!' })
        recorder.flush()

        local edit = events_for(path)[2]
        T.assert_equal(2, edit.offset, 'offset must count codepoints')
        T.assert_equal('!', edit.newFragment)
        teardown()
    end)

    T.it('replays a multibyte session back to the buffer text', function()
        local dir = session()
        local buf, path = open_file(dir, 'prog.py', '# 日本語\n')
        vim.api.nvim_buf_set_text(buf, 0, 11, 0, 11, { 'のコメント' })
        vim.api.nvim_buf_set_lines(buf, 1, 1, false, { 'x = "café"' })
        vim.api.nvim_buf_set_text(buf, 0, 0, 0, 1, { '##' })
        recorder.flush()

        T.assert_equal(recorder._buffer_text(buf), replay(events_for(path)))
        teardown()
    end)
end)

T.describe('recorder: replay fidelity', function()
    T.it('reconstructs the buffer after a long edit sequence', function()
        local dir = session()
        local buf, path = open_file(dir, 'prog.py', 'def main():\n    pass\n')

        vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '    total = 0' })
        vim.api.nvim_buf_set_lines(
            buf,
            2,
            2,
            false,
            { '    for i in range(10):', '        total += i' }
        )
        vim.api.nvim_buf_set_text(buf, 0, 4, 0, 8, { 'run' })
        vim.api.nvim_buf_set_lines(buf, 4, 4, false, { '    return total', '', 'main()' })
        vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
        vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, { '# entry point', '' })
        recorder.flush()

        T.assert_equal(recorder._buffer_text(buf), replay(events_for(path)))
        teardown()
    end)

    T.it('emits one delta per change, not a snapshot per keystroke', function()
        local dir = session()
        local buf, path = open_file(dir, 'prog.py', '\n')
        for i = 1, 20 do
            vim.api.nvim_buf_set_text(buf, 0, i - 1, 0, i - 1, { 'x' })
        end
        recorder.flush()

        local events = events_for(path)
        local snapshots = 0
        for _, event in ipairs(events) do
            if event.offset == 0 and event.oldFragment == event.newFragment then
                snapshots = snapshots + 1
            end
        end
        T.assert_equal(1, snapshots, 'only the initial snapshot should be a snapshot')
        T.assert_equal(21, #events)
        teardown()
    end)
end)

T.describe('recorder: recovery', function()
    T.it('falls back to a snapshot when the baseline is lost', function()
        local dir = session()
        local buf, path = open_file(dir, 'prog.py', 'abc\n')
        vim.api.nvim_buf_set_text(buf, 0, 3, 0, 3, { 'd' })
        recorder.flush()

        -- Simulate the shadow going missing mid-session, the condition the
        -- schema's snapshot escape hatch exists for.
        recorder._state.shadows[vim.api.nvim_buf_get_name(buf)] = nil
        vim.api.nvim_buf_set_text(buf, 0, 4, 0, 4, { 'e' })

        -- The recovery snapshot is queued from a scheduled callback.
        vim.wait(200, function()
            return false
        end)
        recorder.flush()

        local events = events_for(path)
        local last = events[#events]
        T.assert_equal(0, last.offset)
        T.assert_equal(last.oldFragment, last.newFragment)
        T.assert_equal(recorder._buffer_text(buf), last.newFragment)
        T.assert_equal(recorder._buffer_text(buf), replay(events))
        teardown()
    end)

    T.it('keeps recording deltas after recovering', function()
        local dir = session()
        local buf, path = open_file(dir, 'prog.py', 'abc\n')
        vim.api.nvim_buf_set_text(buf, 0, 3, 0, 3, { 'd' })
        recorder._state.shadows[vim.api.nvim_buf_get_name(buf)] = nil
        vim.api.nvim_buf_set_text(buf, 0, 4, 0, 4, { 'e' })
        vim.wait(200, function()
            return false
        end)
        vim.api.nvim_buf_set_text(buf, 0, 5, 0, 5, { 'f' })
        recorder.flush()

        T.assert_equal(recorder._buffer_text(buf), replay(events_for(path)))
        teardown()
    end)
end)

T.describe('recorder: eligibility', function()
    T.it('ignores untracked extensions', function()
        local dir = session()
        local buf, path = open_file(dir, 'notes.txt', 'hello\n')
        vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, { 'x' })
        recorder.flush()
        T.assert_same({}, lines_for(path))
        teardown()
    end)

    T.it('records every whitelisted extension', function()
        for _, name in ipairs({ 'a.py', 'b.h', 'c.hpp', 'd.cpp', 'e.java' }) do
            local dir = session()
            local buf, path = open_file(dir, name, 'x\n')
            vim.api.nvim_buf_set_text(buf, 0, 1, 0, 1, { 'y' })
            recorder.flush()
            T.assert_true(#lines_for(path) > 0, name .. ' should be recorded')
            teardown()
        end
    end)

    T.it('ignores files outside the workspace roots', function()
        local dir = session()
        local outside = T.temp_dir()
        local buf, path = open_file(outside, 'stray.py', 'x\n')
        vim.api.nvim_buf_set_text(buf, 0, 1, 0, 1, { 'y' })
        recorder.flush()
        T.assert_same({}, lines_for(path))
        T.assert_true(dir ~= outside)
        teardown()
    end)

    T.it('resolves a relative root against the working directory', function()
        -- A root left relative would never match an absolute buffer name, and the
        -- recorder would quietly record nothing.
        if recorder.is_recording() then
            recorder.stop()
        end
        local dir = T.temp_dir()
        local previous_cwd = vim.fn.getcwd()
        vim.fn.chdir(dir)

        config.setup({ roots = { '.' }, notify = false, resume_prompt = false })
        intercept()
        recorder.start()

        local buf, path = open_file(dir, 'prog.py', 'x\n')
        vim.api.nvim_buf_set_text(buf, 0, 1, 0, 1, { 'y' })
        recorder.flush()
        local recorded = #lines_for(path) > 0

        teardown()
        vim.fn.chdir(previous_cwd)
        T.assert_true(recorded, 'a relative root must still record')
    end)

    T.it('expands a root written with a tilde', function()
        config.setup({ roots = { '~' }, notify = false, resume_prompt = false })
        if recorder.is_recording() then
            recorder.stop()
        end
        intercept()
        recorder.start()
        for _, root in ipairs(recorder.status().roots) do
            T.assert_false(root:find('~', 1, true) ~= nil, 'tilde must be expanded: ' .. root)
        end
        teardown()
    end)

    T.it('never records its own output files', function()
        local dir = session()
        T.assert_false(recorder._should_record(vim.fn.bufadd(dir .. '/prog.recording.jsonl.gz')))
        teardown()
    end)
end)

T.describe('recorder: status events', function()
    T.it('writes focusStatus to every actively recording document', function()
        local dir = session()
        local buf_a, path_a = open_file(dir, 'a.py', 'x\n')
        vim.api.nvim_buf_set_text(buf_a, 0, 1, 0, 1, { 'y' })
        local buf_b, path_b = open_file(dir, 'b.py', 'x\n')
        vim.api.nvim_buf_set_text(buf_b, 0, 1, 0, 1, { 'y' })
        recorder.flush()

        recorder.queue_status_event('focusStatus', { { 'focused', false } })
        recorder.flush()

        for _, path in ipairs({ path_a, path_b }) do
            local events = events_for(path)
            local last = events[#events]
            T.assert_equal('focusStatus', last.type)
            T.assert_equal(false, last.focused)
        end
        teardown()
    end)

    T.it('does not write focusStatus to a merely-open document', function()
        local dir = session()
        local _, path = open_file(dir, 'idle.py', 'x\n')
        recorder.flush()
        recorder.queue_status_event('focusStatus', { { 'focused', true } })
        recorder.flush()
        T.assert_same({}, lines_for(path))
        teardown()
    end)

    T.it('ignores status events while stopped', function()
        config.setup({ notify = false })
        recorder.queue_status_event('focusStatus', { { 'focused', true } })
        T.assert_false(recorder.is_recording())
        config.reset()
    end)
end)

T.describe('recorder: lifecycle', function()
    T.it('reports recording state', function()
        local dir = session()
        T.assert_true(recorder.is_recording())
        T.assert_true(dir ~= nil)
        recorder.stop()
        T.assert_false(recorder.is_recording())
        restore()
        config.reset()
    end)

    T.it('ignores a redundant start', function()
        session()
        recorder.start()
        T.assert_true(recorder.is_recording())
        teardown()
    end)

    T.it('ignores a redundant stop', function()
        session()
        recorder.stop()
        recorder.stop()
        T.assert_false(recorder.is_recording())
        restore()
        config.reset()
    end)

    T.it('reports edited documents in status()', function()
        local dir = session()
        local buf = open_file(dir, 'prog.py', 'x\n')
        vim.api.nvim_buf_set_text(buf, 0, 1, 0, 1, { 'y' })
        recorder.flush()

        local status = recorder.status()
        T.assert_true(status.recording)
        T.assert_equal(1, #status.documents)
        teardown()
    end)

    T.it('stops capturing after stop', function()
        local dir = session()
        local buf, path = open_file(dir, 'prog.py', 'x\n')
        vim.api.nvim_buf_set_text(buf, 0, 1, 0, 1, { 'y' })
        recorder.flush()
        local before = #lines_for(path)

        recorder.stop()
        vim.api.nvim_buf_set_text(buf, 0, 1, 0, 1, { 'z' })
        recorder.flush()

        T.assert_equal(before, #lines_for(path))
        restore()
        config.reset()
    end)
end)

T.describe('recorder: batching', function()
    T.it('keeps each document in its own file', function()
        local dir = session()
        local buf_a, path_a = open_file(dir, 'a.py', 'a\n')
        local buf_b, path_b = open_file(dir, 'b.py', 'b\n')
        vim.api.nvim_buf_set_text(buf_a, 0, 1, 0, 1, { '1' })
        vim.api.nvim_buf_set_text(buf_b, 0, 1, 0, 1, { '2' })
        vim.api.nvim_buf_set_text(buf_a, 0, 2, 0, 2, { '3' })
        recorder.flush()

        T.assert_equal('a\n', replay({ events_for(path_a)[1] }))
        T.assert_equal(recorder._buffer_text(buf_a), replay(events_for(path_a)))
        T.assert_equal(recorder._buffer_text(buf_b), replay(events_for(path_b)))
        teardown()
    end)
end)
