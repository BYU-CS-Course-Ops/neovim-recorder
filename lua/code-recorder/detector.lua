--- Offers to resume recording when an existing recording file is found.
---
--- Mirrors the VS Code and JetBrains recorders: if a student reopens a file that
--- already has a `.recording.jsonl.gz` beside it and the recorder is not running,
--- they are asked once whether to pick the session back up. Prompting is capped
--- at once per session so it never becomes noise.

local config = require('code-recorder.config')
local log = require('code-recorder.log')
local recorder = require('code-recorder.recorder')
local writer = require('code-recorder.writer')

local M = {}

local prompted = false

--- Resets the prompt latch so the question can be asked again after a stop.
function M.reset()
    prompted = false
end

local function recording_exists(path)
    return vim.uv.fs_stat(writer.recording_path(path)) ~= nil
end

local function ask(path)
    local name = vim.fs.basename(path)
    local message =
        string.format("A recording file exists for '%s'. Would you like to resume recording?", name)

    local mode = config.get().resume_prompt

    if mode == 'notify' then
        vim.notify(message .. ' Run :CodeRecorderStart to resume.', vim.log.levels.INFO)
        return
    end

    vim.ui.select({ 'Resume Recording', 'Dismiss' }, { prompt = message }, function(choice)
        if choice == 'Resume Recording' then
            log.info('Recording resumed from user prompt')
            recorder.start()
        else
            log.debug('User dismissed resume recording prompt')
        end
    end)
end

--- Considers `buf` for a resume prompt.
--- @param buf integer
function M.check(buf)
    if not config.get().resume_prompt then
        return
    end
    if prompted or recorder.is_recording() then
        return
    end
    -- Never interrupt startup; wait until the UI is up and settled.
    if vim.v.vim_did_enter == 0 then
        return
    end

    if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then
        return
    end

    local path = vim.api.nvim_buf_get_name(buf)
    if path == '' or writer.is_recording_file(path) then
        return
    end
    if not recording_exists(path) then
        return
    end

    prompted = true
    log.info('Existing recording file detected for ' .. path)
    vim.schedule(function()
        ask(path)
    end)
end

--- Installs the autocommands that watch for reopened recordings.
function M.setup()
    local group = vim.api.nvim_create_augroup('CodeRecorderDetector', { clear = true })

    vim.api.nvim_create_autocmd({ 'BufEnter', 'BufReadPost' }, {
        group = group,
        callback = function(args)
            M.check(args.buf)
        end,
    })

    -- Asking again is reasonable once the user has explicitly stopped.
    table.insert(recorder.callbacks.on_state_changed, function(recording)
        if recording then
            prompted = false
        end
    end)
end

return M
