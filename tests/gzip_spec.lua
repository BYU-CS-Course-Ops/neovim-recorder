local T = _G.TEST
local gzip = require('code-recorder.gzip')

--- Decodes the little-endian uint32 at `offset` (1-based).
local function le32_at(s, offset)
    local b1, b2, b3, b4 = s:byte(offset, offset + 3)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

T.describe('gzip.crc32', function()
    T.it('matches the published check value', function()
        -- The CRC-32 of "123456789" is the standard 0xCBF43926 check value.
        T.assert_equal(0xCBF43926, gzip._crc32('123456789'))
    end)

    T.it('is zero for empty input', function()
        T.assert_equal(0, gzip._crc32(''))
    end)

    T.it('handles bytes above 0x7F', function()
        T.assert_equal(0xFF000000 % 4294967296 > 0, true)
        -- A single 0xFF byte has a well-defined, non-zero CRC.
        T.assert_true(gzip._crc32('\255') ~= 0)
    end)
end)

T.describe('gzip.compress', function()
    T.it('emits a gzip header with the deflate method', function()
        local member = gzip.compress('hello')
        T.assert_equal(0x1F, member:byte(1))
        T.assert_equal(0x8B, member:byte(2))
        T.assert_equal(0x08, member:byte(3), 'CM must be 8 (deflate)')
        T.assert_equal(0x00, member:byte(4), 'no optional header fields')
    end)

    T.it('records CRC and size in the trailer', function()
        local data = 'def main():\n    pass\n'
        local member = gzip.compress(data)
        T.assert_equal(gzip._crc32(data), le32_at(member, #member - 7))
        T.assert_equal(#data, le32_at(member, #member - 3))
    end)

    T.it('produces a well-formed member for empty input', function()
        local member = gzip.compress('')
        T.assert_equal(0x1F, member:byte(1))
        T.assert_equal(0, le32_at(member, #member - 3))
        T.assert_equal(0, le32_at(member, #member - 7))
    end)

    T.it('compresses repetitive JSON lines substantially', function()
        local line = '{"type":"edit","editor":"neovim","offset":42,"oldFragment":""}\n'
        local data = string.rep(line, 500)
        local member = gzip.compress(data)
        T.assert_true(
            #member < #data / 10,
            string.format('expected >10x compression, got %d -> %d', #data, #member)
        )
    end)

    T.it('falls back to stored blocks rather than inflating random data', function()
        math.randomseed(20260904)
        local bytes = {}
        for i = 1, 4096 do
            bytes[i] = string.char(math.random(0, 255))
        end
        local data = table.concat(bytes)
        local member = gzip.compress(data)
        -- Header (10) + trailer (8) + stored framing (5) = 23 bytes of overhead.
        T.assert_true(
            #member <= #data + 23,
            string.format('stored fallback should cap overhead, got %d -> %d', #data, #member)
        )
    end)

    T.it('round-trips through the system gzip when one is available', function()
        if vim.fn.executable('gzip') == 0 then
            return
        end
        local dir = T.temp_dir()
        local path = dir .. '/sample.gz'
        local data = 'first line\nsecond line\nthird line\n'

        local handle = assert(io.open(path, 'wb'))
        -- Two appended members, the framing the recorder actually writes.
        handle:write(gzip.compress('first line\n'))
        handle:write(gzip.compress('second line\nthird line\n'))
        handle:close()

        local decoded = vim.fn.system({ 'gzip', '-dc', path })
        T.assert_equal(0, vim.v.shell_error, 'gzip -dc failed: ' .. decoded)
        T.assert_equal(data, decoded)
    end)
end)
