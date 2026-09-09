--- User-facing configuration, with the defaults chosen to match the VS Code and
--- JetBrains recorders wherever the editors make that possible.

local M = {}

--- File extensions the recorder is allowed to track.
---
--- Mirrors the JetBrains and VS Code whitelists so all three editors record the
--- same set of files, and keeps the recorder from picking up incidental buffers
--- (generated HTML reports, scratch notes) that happen to be open.
-- stylua: ignore
local DEFAULT_TRACKED_EXTENSIONS = {
    -- python
    '.py',
    -- c++
    '.h', '.hpp', '.cpp',
    -- java
    '.java',
}

--- @class CodeRecorderConfig
--- @field tracked_extensions string[] Extensions eligible for recording.
--- @field batch_idle_ms integer Idle time before a batch is flushed to disk.
--- @field auto_start boolean Start recording on VimEnter regardless of history.
--- @field resume_previous_session boolean Resume if the last session was recording.
--- @field resume_prompt string|false "select", "notify", or false.
--- @field roots string[]|nil Explicit workspace roots; nil means use the cwd.
--- @field notify boolean Emit user-facing notifications for start/stop.
--- @field log_level integer Minimum vim.log.level written to the debug log.
local defaults = {
    tracked_extensions = DEFAULT_TRACKED_EXTENSIONS,
    batch_idle_ms = 1000,
    auto_start = false,
    resume_previous_session = true,
    resume_prompt = 'select',
    roots = nil,
    notify = true,
    log_level = vim.log.levels.INFO,
}

local current = vim.deepcopy(defaults)

--- Returns the active configuration table.
--- @return CodeRecorderConfig
function M.get()
    return current
end

--- Merges user options over the defaults.
--- @param opts table|nil
--- @return CodeRecorderConfig
function M.setup(opts)
    current = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})

    -- `tbl_deep_extend` merges list-like tables by index rather than replacing
    -- them, which would leave stale defaults behind a shorter user list.
    if opts and opts.tracked_extensions then
        current.tracked_extensions = vim.deepcopy(opts.tracked_extensions)
    end
    if opts and opts.roots then
        current.roots = vim.deepcopy(opts.roots)
    end

    return current
end

--- Restores defaults. Used by the test suite.
function M.reset()
    current = vim.deepcopy(defaults)
    return current
end

M.defaults = defaults

return M
