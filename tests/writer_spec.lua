local T = _G.TEST
local writer = require('code-recorder.writer')
local RECORDER_VERSION = require('code-recorder.version')

T.describe('writer.recording_path', function()
    T.it('replaces the final extension', function()
        T.assert_equal(
            '/home/s/hw/prog.recording.jsonl.gz',
            writer.recording_path('/home/s/hw/prog.py')
        )
    end)

    T.it('preserves Windows separators', function()
        T.assert_equal([[C:\hw\prog.recording.jsonl.gz]], writer.recording_path([[C:\hw\prog.py]]))
    end)

    T.it('only strips the last extension', function()
        T.assert_equal(
            '/a/b/main.test.recording.jsonl.gz',
            writer.recording_path('/a/b/main.test.cpp')
        )
    end)

    T.it('keeps the whole name for a dotfile', function()
        T.assert_equal('/a/.bashrc.recording.jsonl.gz', writer.recording_path('/a/.bashrc'))
    end)

    T.it('handles a bare filename', function()
        T.assert_equal('prog.recording.jsonl.gz', writer.recording_path('prog.py'))
    end)
end)

T.describe('writer.is_recording_file', function()
    T.it('detects recording output', function()
        T.assert_true(writer.is_recording_file('/a/prog.recording.jsonl.gz'))
    end)

    T.it('leaves source files alone', function()
        T.assert_false(writer.is_recording_file('/a/prog.py'))
    end)
end)

T.describe('writer.timestamp', function()
    T.it('renders ISO-8601 UTC with milliseconds', function()
        T.assert_match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ$', writer.timestamp())
    end)
end)

T.describe('writer.encode_edit', function()
    local line = writer.encode_edit({
        timestamp = '2026-09-04T04:07:00.902Z',
        document = '/tmp/prog.py',
        offset = 42,
        old_fragment = 'old',
        new_fragment = 'new',
    })

    T.it('emits schema keys in documented order', function()
        T.assert_equal(
            '{"type":"edit","editor":"neovim","recorderVersion":"'
                .. RECORDER_VERSION
                .. '",'
                .. '"timestamp":"2026-09-04T04:07:00.902Z","document":"/tmp/prog.py",'
                .. '"offset":42,"oldFragment":"old","newFragment":"new"}',
            line
        )
    end)

    T.it('parses back to the expected object', function()
        local decoded = vim.json.decode(line)
        T.assert_equal('edit', decoded.type)
        T.assert_equal('neovim', decoded.editor)
        T.assert_equal(42, decoded.offset)
    end)

    T.it('escapes newlines and quotes in fragments', function()
        local encoded = writer.encode_edit({
            timestamp = 'T',
            document = 'd',
            offset = 0,
            old_fragment = '',
            new_fragment = 'print("hi")\n\tdone\\',
        })
        T.assert_false(encoded:find('\n', 1, true) ~= nil, 'raw newline must not appear')
        T.assert_equal('print("hi")\n\tdone\\', vim.json.decode(encoded).newFragment)
    end)

    T.it('round-trips multibyte fragments', function()
        local encoded = writer.encode_edit({
            timestamp = 'T',
            document = 'd',
            offset = 0,
            old_fragment = '',
            new_fragment = '日本語 café',
        })
        T.assert_equal('日本語 café', vim.json.decode(encoded).newFragment)
    end)
end)

T.describe('writer.encode_status', function()
    T.it('emits focusStatus in documented order', function()
        T.assert_equal(
            '{"type":"focusStatus","editor":"neovim","recorderVersion":"'
                .. RECORDER_VERSION
                .. '",'
                .. '"timestamp":"2026-09-04T04:07:00.902Z","focused":true}',
            writer.encode_status('focusStatus', '2026-09-04T04:07:00.902Z', { { 'focused', true } })
        )
    end)

    T.it('supports an empty field list', function()
        local decoded = vim.json.decode(writer.encode_status('focusStatus', 'T', {}))
        T.assert_equal('focusStatus', decoded.type)
    end)
end)

T.describe('writer.append', function()
    T.it('creates the file and accumulates members', function()
        local dir = T.temp_dir()
        local path = dir .. '/prog.recording.jsonl.gz'

        T.assert_true(writer.append(path, { 'line one' }))
        local first = vim.uv.fs_stat(path).size

        T.assert_true(writer.append(path, { 'line two', 'line three' }))
        T.assert_true(vim.uv.fs_stat(path).size > first, 'second append must grow the file')
    end)

    T.it('is a no-op for an empty batch', function()
        local dir = T.temp_dir()
        local path = dir .. '/empty.recording.jsonl.gz'
        T.assert_true(writer.append(path, {}))
        T.assert_equal(nil, vim.uv.fs_stat(path))
    end)

    T.it('reports failure for an unwritable path', function()
        local ok = writer.append(T.temp_dir() .. '/missing-dir/out.gz', { 'x' })
        T.assert_false(ok)
    end)
end)
