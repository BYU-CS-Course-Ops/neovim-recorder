--- Statusline component, the analogue of the VS Code status bar item and the
--- JetBrains status widget.
---
--- Neovim has no shared status bar API, so this exposes a plain string function
--- users drop into `statusline`, lualine, heirline, or whatever they run. The
--- indicator briefly changes glyph when an edit is recorded, matching the flash
--- the other two recorders show.

local recorder = require('code-recorder.recorder')

local M = {}

local ACTIVE = 'REC'
local INACTIVE = 'REC off'
local FLASH = 'REC*'
local FLASH_MS = 150

local flashing = false
local flash_timer = nil

--- Renders the recorder indicator.
---
--- Example, in a plain statusline:
--- ```lua
--- vim.o.statusline = "%f %=%{v:lua.require'code-recorder.status'.component()}"
--- ```
--- @return string
function M.component()
    if not recorder.is_recording() then
        return INACTIVE
    end
    return flashing and FLASH or ACTIVE
end

--- Highlight group name appropriate to the current state, for statusline plugins
--- that want colour.
--- @return string
function M.highlight()
    if not recorder.is_recording() then
        return 'CodeRecorderInactive'
    end
    return flashing and 'CodeRecorderFlash' or 'CodeRecorderActive'
end

local function redraw()
    vim.schedule(function()
        vim.cmd('redrawstatus')
    end)
end

local function flash()
    if not recorder.is_recording() then
        return
    end

    flashing = true
    redraw()

    if flash_timer then
        flash_timer:stop()
    else
        flash_timer = vim.uv.new_timer()
    end

    flash_timer:start(
        FLASH_MS,
        0,
        vim.schedule_wrap(function()
            flashing = false
            vim.cmd('redrawstatus')
        end)
    )
end

--- Registers highlight groups and hooks the recorder's callbacks.
function M.setup()
    vim.api.nvim_set_hl(0, 'CodeRecorderActive', { fg = '#2E7D32', default = true })
    vim.api.nvim_set_hl(0, 'CodeRecorderInactive', { fg = '#B71C1C', default = true })
    vim.api.nvim_set_hl(0, 'CodeRecorderFlash', { fg = '#00E676', default = true })

    table.insert(recorder.callbacks.on_state_changed, function()
        flashing = false
        redraw()
    end)
    table.insert(recorder.callbacks.on_document_recorded, flash)
end

return M
