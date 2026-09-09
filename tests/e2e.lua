--- Produces a real recording on disk for `tests/verify_e2e.py` to check.
---
--- The Lua suite stubs out the writer so it can assert on JSON lines. This one
--- does not: it drives the recorder end to end and leaves genuine gzip files
--- behind, so the bytes an analyst receives are what gets validated.
---
--- Usage: `nvim -l tests/e2e.lua <output-dir>`

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local config = require('code-recorder.config')
local recorder = require('code-recorder.recorder')

local out_dir = _G.arg[1]
if not out_dir or out_dir == '' then
    io.stderr:write('usage: nvim -l tests/e2e.lua <output-dir>\n')
    os.exit(2)
end

vim.fn.mkdir(out_dir, 'p')

local function write_file(path, contents)
    local handle = assert(io.open(path, 'wb'))
    handle:write(contents)
    handle:close()
end

config.setup({ roots = { out_dir }, notify = false, resume_prompt = false })

-- A file that is opened and edited, and one that is only ever opened.
local edited_path = out_dir .. '/homework.py'
local untouched_path = out_dir .. '/scratch.py'
write_file(edited_path, 'def main():\n    pass\n')
write_file(untouched_path, '# never edited\n')

recorder.start()

vim.cmd.edit(vim.fn.fnameescape(untouched_path))
vim.cmd.edit(vim.fn.fnameescape(edited_path))
local buf = vim.api.nvim_get_current_buf()

-- A pasted block, character-by-character typing, a deletion, and multibyte text:
-- roughly the shapes recan classifies.
vim.api.nvim_buf_set_lines(buf, 1, 2, false, {
    '    total = 0',
    '    for i in range(10):',
    '        total += i',
})
recorder.flush()

recorder.queue_status_event('focusStatus', { { 'focused', false } })
recorder.queue_status_event('focusStatus', { { 'focused', true } })
recorder.flush()

-- Character-by-character typing of a new final line, the shape recan reads as
-- genuine authoring rather than a paste.
local typed = '    print(total)'
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '' })
local last_row = vim.api.nvim_buf_line_count(buf) - 1
for i = 1, #typed do
    vim.api.nvim_buf_set_text(buf, last_row, i - 1, last_row, i - 1, { typed:sub(i, i) })
end
recorder.flush()

-- A rename, a multibyte header, and a deletion.
vim.api.nvim_buf_set_text(buf, 0, 4, 0, 8, { 'run' })
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { '# 日本語 café — entry point' })
vim.api.nvim_buf_set_lines(buf, 3, 4, false, {})
recorder.flush()

local final_text = recorder._buffer_text(buf)
recorder.stop()

write_file(out_dir .. '/homework.expected', final_text)

io.write(
    string.format(
        'recording: %s (%d bytes)\nexpected:  %d bytes\n',
        edited_path,
        vim.uv.fs_stat(out_dir .. '/homework.recording.jsonl.gz').size,
        #final_text
    )
)

-- The unedited file must have produced nothing at all.
if vim.uv.fs_stat(out_dir .. '/scratch.recording.jsonl.gz') then
    io.stderr:write('FAIL: an unedited file produced a recording\n')
    os.exit(1)
end
