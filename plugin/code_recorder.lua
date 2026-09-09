-- Bootstrap for the BYU CS Code Recorder.
--
-- The VS Code and JetBrains recorders activate on their own once installed, and
-- students should not have to write config for a course tool. So if `setup` has
-- not been called by the time the editor is up, the defaults are applied here.
-- Calling `require('code-recorder').setup{...}` from your config still wins.

if vim.g.loaded_code_recorder == 1 then
    return
end
vim.g.loaded_code_recorder = 1

if vim.fn.has('nvim-0.10') == 0 then
    vim.notify(
        'code-recorder requires Neovim 0.10 or newer (nvim_buf_attach on_bytes and vim.uv).',
        vim.log.levels.ERROR
    )
    return
end

vim.api.nvim_create_autocmd('VimEnter', {
    group = vim.api.nvim_create_augroup('CodeRecorderBootstrap', { clear = true }),
    once = true,
    nested = true,
    callback = function()
        local code_recorder = require('code-recorder')
        if not code_recorder.is_initialised() then
            code_recorder.setup()
        end
    end,
})
