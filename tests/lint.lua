--- Checks that every Lua file in the plugin loads.
---
--- Catches syntax errors that the test suite would otherwise only surface for the
--- modules it happens to require.
---
--- Usage: `nvim -l tests/lint.lua`

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local failures = 0
local checked = 0

for _, dir in ipairs({ 'lua', 'plugin', 'tests' }) do
    for _, path in ipairs(vim.fn.globpath(root .. '/' .. dir, '**/*.lua', false, true)) do
        checked = checked + 1
        local chunk, err = loadfile(path)
        if not chunk then
            failures = failures + 1
            io.write('  FAIL ', path, '\n    ', tostring(err), '\n')
        end
    end
end

io.write(string.format('%d file(s) checked, %d failed\n', checked, failures))
os.exit(failures == 0 and 0 or 1)
