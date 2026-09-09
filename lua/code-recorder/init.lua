--- BYU CS Code Recorder for Neovim.
---
--- Records every edit a student makes to whitelisted source files and writes it
--- to `{basename}.recording.jsonl.gz` beside the file, in the schema shared with
--- the VS Code and JetBrains recorders and consumed by `recan`.
---
--- Minimal setup:
--- ```lua
--- require('code-recorder').setup()
--- ```

local config = require('code-recorder.config')
local detector = require('code-recorder.detector')
local log = require('code-recorder.log')
local recorder = require('code-recorder.recorder')
local status = require('code-recorder.status')

local M = {}

M.start = recorder.start
M.stop = recorder.stop
M.toggle = recorder.toggle
M.is_recording = recorder.is_recording
M.status = recorder.status
M.flush = recorder.flush
M.statusline = status.component

local initialised = false

--------------------------------------------------------------------------------
-- Cross-session state
--------------------------------------------------------------------------------

--- Path of the file remembering whether the last session was recording.
---
--- The reference recorders lean on their IDE's global state store; Neovim has no
--- equivalent, so this is a small JSON file under `stdpath('data')`.
local function state_path()
    return vim.fs.joinpath(vim.fn.stdpath('data'), 'code-recorder', 'state.json')
end

local function read_state()
    local path = state_path()
    local handle = io.open(path, 'r')
    if not handle then
        return {}
    end
    local contents = handle:read('*a')
    handle:close()

    local ok, decoded = pcall(vim.json.decode, contents)
    if not ok or type(decoded) ~= 'table' then
        return {}
    end
    return decoded
end

local function write_state(value)
    local path = state_path()
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local handle = io.open(path, 'w')
    if not handle then
        log.debug('Could not persist recorder state to ' .. path)
        return
    end
    handle:write(vim.json.encode(value))
    handle:close()
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function describe_status()
    local snapshot = recorder.status()
    if not snapshot.recording then
        return 'Code Recorder: stopped'
    end

    local lines = {
        'Code Recorder: recording',
        '  roots:     ' .. table.concat(snapshot.roots, ', '),
        '  buffers:   ' .. snapshot.attached .. ' attached',
        '  documents: ' .. #snapshot.documents .. ' edited',
    }
    for _, document in ipairs(snapshot.documents) do
        lines[#lines + 1] = '    ' .. document
    end
    if snapshot.pending > 0 then
        lines[#lines + 1] = '  pending:   ' .. snapshot.pending .. ' event(s)'
    end
    return table.concat(lines, '\n')
end

local function create_commands()
    local command = vim.api.nvim_create_user_command

    command('CodeRecorderStart', function()
        recorder.start()
    end, { desc = 'Start recording code changes' })

    command('CodeRecorderStop', function()
        recorder.stop()
    end, { desc = 'Stop recording code changes' })

    command('CodeRecorderToggle', function()
        recorder.toggle()
    end, { desc = 'Toggle code recording' })

    command('CodeRecorderStatus', function()
        vim.notify(describe_status(), vim.log.levels.INFO)
    end, { desc = 'Show code recorder status' })

    command('CodeRecorderFlush', function()
        recorder.flush()
    end, { desc = 'Flush pending recorder events to disk' })

    command('CodeRecorderLog', function()
        log.show()
    end, { desc = 'Open the code recorder log' })
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

--- Configures and activates the plugin.
--- @param opts table|nil See `code-recorder.config` for the accepted keys.
function M.setup(opts)
    if initialised then
        config.setup(opts)
        return
    end
    initialised = true

    local settings = config.setup(opts)

    create_commands()
    status.setup()
    detector.setup()

    -- Remember the recording state so a restart can pick the session back up,
    -- matching the VS Code extension's `wasRecording` global state.
    table.insert(recorder.callbacks.on_state_changed, function(recording)
        write_state({ wasRecording = recording })
    end)

    local group = vim.api.nvim_create_augroup('CodeRecorder', { clear = true })
    vim.api.nvim_create_autocmd('VimEnter', {
        group = group,
        once = true,
        callback = function()
            local resume = settings.resume_previous_session and read_state().wasRecording
            if settings.auto_start or resume then
                if resume then
                    log.info('Resuming recording from previous session')
                end
                recorder.start()
            end
        end,
    })

    -- `setup` is often called from a lazy-loaded plugin spec, after VimEnter has
    -- already fired, in which case the autocommand above never runs.
    if vim.v.vim_did_enter == 1 then
        vim.schedule(function()
            local resume = settings.resume_previous_session and read_state().wasRecording
            if (settings.auto_start or resume) and not recorder.is_recording() then
                recorder.start()
            end
        end)
    end
end

--- Reports whether `setup` has already run, so the plugin bootstrap can default
--- users who never call it into the standard configuration.
--- @return boolean
function M.is_initialised()
    return initialised
end

M._state_path = state_path

return M
