--- Minimal test runner.
---
--- Run with `nvim -l tests/run.lua`. Pass spec names to run a subset:
--- `nvim -l tests/run.lua writer recorder`.
---
--- Neovim is the only dependency; there is no busted/plenary requirement so the
--- suite runs anywhere the plugin does.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local T = {}

local failures = {}
local passed = 0
local current = nil

--- Declares a group of tests.
function T.describe(name, body)
    current = name
    local ok, err = pcall(body)
    if not ok then
        failures[#failures + 1] = { name = name .. ' (group)', message = tostring(err) }
    end
    current = nil
end

--- Declares a single test.
function T.it(name, body)
    local label = string.format('%s :: %s', current or '?', name)
    local ok, err = pcall(body)
    if ok then
        passed = passed + 1
        io.write('  ok   ', label, '\n')
    else
        failures[#failures + 1] = { name = label, message = tostring(err) }
        io.write('  FAIL ', label, '\n')
    end
end

local function fail(message, level)
    error(message, (level or 2) + 1)
end

function T.assert_true(value, message)
    if not value then
        fail(message or ('expected truthy, got ' .. vim.inspect(value)))
    end
end

function T.assert_false(value, message)
    if value then
        fail(message or ('expected falsey, got ' .. vim.inspect(value)))
    end
end

function T.assert_equal(expected, actual, message)
    if expected ~= actual then
        fail(
            string.format(
                '%sexpected %s, got %s',
                message and (message .. ': ') or '',
                vim.inspect(expected),
                vim.inspect(actual)
            )
        )
    end
end

function T.assert_same(expected, actual, message)
    if not vim.deep_equal(expected, actual) then
        fail(
            string.format(
                '%sexpected %s, got %s',
                message and (message .. ': ') or '',
                vim.inspect(expected),
                vim.inspect(actual)
            )
        )
    end
end

function T.assert_match(pattern, actual, message)
    if type(actual) ~= 'string' or not actual:match(pattern) then
        fail(
            string.format(
                '%sexpected %s to match %s',
                message and (message .. ': ') or '',
                vim.inspect(actual),
                vim.inspect(pattern)
            )
        )
    end
end

--- Creates a unique temporary directory that is removed when the suite ends.
local temp_dirs = {}
function T.temp_dir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    temp_dirs[#temp_dirs + 1] = dir
    return dir
end

_G.TEST = T

local specs = { 'gzip_spec', 'writer_spec', 'config_spec', 'recorder_spec' }
if #_G.arg > 0 then
    specs = _G.arg
end

for _, spec in ipairs(specs) do
    io.write(spec, '\n')
    dofile(root .. '/tests/' .. spec:gsub('%.lua$', '') .. '.lua')
end

for _, dir in ipairs(temp_dirs) do
    pcall(vim.fn.delete, dir, 'rf')
end

io.write(string.format('\n%d passed, %d failed\n', passed, #failures))
for _, failure in ipairs(failures) do
    io.write('\nFAIL ', failure.name, '\n  ', failure.message, '\n')
end

os.exit(#failures == 0 and 0 or 1)
