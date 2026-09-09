--- In-memory diagnostic log, the analogue of the VS Code recorder's output
--- channel and the JetBrains recorder's `Logger`.
---
--- Kept in a ring buffer so a long session cannot grow without bound, and
--- surfaced through `:CodeRecorderLog`.

local config = require('code-recorder.config')

local M = {}

local MAX_LINES = 2000

local lines = {}

--- Appends a line to the log, and notifies the user when the level warrants it.
--- @param level integer A `vim.log.levels` value.
--- @param message string
function M.write(level, message)
    local stamped = string.format('[%s] %s', os.date('%H:%M:%S'), message)
    lines[#lines + 1] = stamped
    if #lines > MAX_LINES then
        table.remove(lines, 1)
    end

    if level >= vim.log.levels.WARN then
        vim.schedule(function()
            vim.notify('Code Recorder: ' .. message, level)
        end)
    end
end

function M.debug(message)
    if config.get().log_level <= vim.log.levels.DEBUG then
        M.write(vim.log.levels.DEBUG, message)
    end
end

function M.info(message)
    M.write(vim.log.levels.INFO, message)
end

function M.warn(message)
    M.write(vim.log.levels.WARN, message)
end

function M.error(message)
    M.write(vim.log.levels.ERROR, message)
end

--- Returns a copy of the buffered log lines.
--- @return string[]
function M.get()
    return vim.deepcopy(lines)
end

function M.clear()
    lines = {}
end

--- Opens the log in a scratch buffer.
function M.show()
    local buf = vim.api.nvim_create_buf(false, true)
    local content = #lines > 0 and lines or { '(no log entries yet)' }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = 'wipe'
    vim.api.nvim_buf_set_name(buf, 'code-recorder://log')
    vim.cmd.split()
    vim.api.nvim_win_set_buf(0, buf)
end

return M
