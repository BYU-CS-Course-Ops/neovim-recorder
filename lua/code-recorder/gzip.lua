--- Dependency-free gzip encoder.
---
--- Neovim ships no zlib binding and students cannot be assumed to have a `gzip`
--- binary on PATH, so the recorder carries its own DEFLATE encoder.
---
--- Each `compress` call returns one complete, standalone gzip member. Appending
--- members to a file yields a valid `.gz`: Python's `gzip` module (which is what
--- `recan` uses) decodes concatenated members as a single stream. That is the
--- same framing the VS Code and JetBrains recorders produce, where every flushed
--- batch is its own member.
---
--- Blocks are emitted with the fixed Huffman code (RFC 1951 section 3.2.6) over
--- greedily matched LZ77 output, falling back to a stored block whenever
--- compression would not pay for itself.

local M = {}

local byte, char, sub = string.byte, string.char, string.sub
local concat = table.concat
local floor = math.floor

local UINT32 = 4294967296

--------------------------------------------------------------------------------
-- Bitwise helpers
--------------------------------------------------------------------------------

--- 32-bit exclusive-or, normalised to an unsigned value.
---
--- LuaJIT (what Neovim embeds) provides `bit`; the pure-Lua fallback keeps this
--- module usable under a plain `lua` interpreter for offline testing.
local xor
do
    local ok, bitlib = pcall(require, 'bit')
    if ok then
        local bxor = bitlib.bxor
        xor = function(a, b)
            return bxor(a, b) % UINT32
        end
    else
        local nibble = {}
        for a = 0, 15 do
            nibble[a] = {}
            for b = 0, 15 do
                local result, mask, x, y = 0, 1, a, b
                for _ = 1, 4 do
                    if x % 2 ~= y % 2 then
                        result = result + mask
                    end
                    x, y, mask = floor(x / 2), floor(y / 2), mask * 2
                end
                nibble[a][b] = result
            end
        end
        xor = function(a, b)
            local result, mask = 0, 1
            for _ = 1, 8 do
                result = result + nibble[a % 16][b % 16] * mask
                a, b, mask = floor(a / 16), floor(b / 16), mask * 16
            end
            return result
        end
    end
end

local CRC_TABLE = {}
for n = 0, 255 do
    local c = n
    for _ = 1, 8 do
        if c % 2 == 1 then
            c = xor(floor(c / 2), 0xEDB88320)
        else
            c = floor(c / 2)
        end
    end
    CRC_TABLE[n] = c
end

--- CRC-32 of `data`, as required by the gzip trailer.
local function crc32(data)
    local c = 0xFFFFFFFF
    for i = 1, #data do
        c = xor(floor(c / 256), CRC_TABLE[xor(c % 256, byte(data, i))])
    end
    return xor(c, 0xFFFFFFFF)
end

local function le32(value)
    value = value % UINT32
    return char(
        value % 256,
        floor(value / 256) % 256,
        floor(value / 65536) % 256,
        floor(value / 16777216) % 256
    )
end

--------------------------------------------------------------------------------
-- Bit writer
--------------------------------------------------------------------------------

local POW = {}
for i = 0, 32 do
    POW[i] = 2 ^ i
end

local Writer = {}
Writer.__index = Writer

local function new_writer()
    return setmetatable({ out = {}, acc = 0, nbits = 0 }, Writer)
end

--- Appends the `nbits` low bits of `value`, least significant bit first.
---
--- That is DEFLATE's packing order for everything except Huffman codes, which go
--- out most significant bit first and are therefore pre-reversed below.
function Writer:put(value, nbits)
    self.acc = self.acc + value * POW[self.nbits]
    self.nbits = self.nbits + nbits
    while self.nbits >= 8 do
        local b = self.acc % 256
        self.out[#self.out + 1] = char(b)
        self.acc = (self.acc - b) / 256
        self.nbits = self.nbits - 8
    end
end

--- Pads the current partial byte with zero bits so the stream is byte-aligned.
function Writer:align()
    if self.nbits > 0 then
        self.out[#self.out + 1] = char(self.acc % 256)
        self.acc, self.nbits = 0, 0
    end
end

--- Appends bytes verbatim, aligning first.
function Writer:raw(str)
    self:align()
    self.out[#self.out + 1] = str
end

--------------------------------------------------------------------------------
-- Fixed Huffman tables (RFC 1951, section 3.2.6)
--------------------------------------------------------------------------------

local function reverse(code, nbits)
    local r = 0
    for _ = 1, nbits do
        r = r * 2 + code % 2
        code = floor(code / 2)
    end
    return r
end

local LIT_CODE, LIT_BITS = {}, {}
for sym = 0, 287 do
    local code, nbits
    if sym <= 143 then
        code, nbits = 0x30 + sym, 8
    elseif sym <= 255 then
        code, nbits = 0x190 + sym - 144, 9
    elseif sym <= 279 then
        code, nbits = sym - 256, 7
    else
        code, nbits = 0xC0 + sym - 280, 8
    end
    LIT_CODE[sym], LIT_BITS[sym] = reverse(code, nbits), nbits
end

local DIST_CODE = {}
for sym = 0, 29 do
    DIST_CODE[sym] = reverse(sym, 5)
end

-- stylua: ignore
local LENGTH_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
-- stylua: ignore
local LENGTH_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
-- stylua: ignore
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
-- stylua: ignore
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }

--- Maps a match length (3..258) to its 1-based index in LENGTH_BASE.
local LENGTH_INDEX = {}
do
    local i = 1
    for len = 3, 258 do
        while i < 29 and LENGTH_BASE[i + 1] <= len do
            i = i + 1
        end
        LENGTH_INDEX[len] = i
    end
end

--- Maps a match distance to its 1-based index in DIST_BASE.
local function dist_index(distance)
    local i = 1
    while i < 30 and DIST_BASE[i + 1] <= distance do
        i = i + 1
    end
    return i
end

--------------------------------------------------------------------------------
-- DEFLATE
--------------------------------------------------------------------------------

local WINDOW = 32768
local MIN_MATCH = 3
local MAX_MATCH = 258
local MAX_CHAIN = 128

local function hash3(data, pos)
    return byte(data, pos) * 65536 + byte(data, pos + 1) * 256 + byte(data, pos + 2)
end

--- Emits `data` as a single final block using the fixed Huffman code.
local function deflate_fixed(data, w)
    w:put(1, 1) -- BFINAL
    w:put(1, 2) -- BTYPE = 01, fixed Huffman

    local n = #data
    local head, prev = {}, {}
    local pos = 1

    while pos <= n do
        local best_len, best_dist = 0, 0

        if pos + MIN_MATCH - 1 <= n then
            local h = hash3(data, pos)
            local limit = n - pos + 1
            if limit > MAX_MATCH then
                limit = MAX_MATCH
            end

            local candidate, chain = head[h], 0
            while candidate and pos - candidate <= WINDOW and chain < MAX_CHAIN do
                local len = 0
                while len < limit and byte(data, candidate + len) == byte(data, pos + len) do
                    len = len + 1
                end
                if len > best_len then
                    best_len, best_dist = len, pos - candidate
                    if len >= limit then
                        break
                    end
                end
                candidate = prev[candidate]
                chain = chain + 1
            end

            prev[pos] = head[h]
            head[h] = pos
        end

        if best_len >= MIN_MATCH then
            local li = LENGTH_INDEX[best_len]
            local sym = 256 + li
            w:put(LIT_CODE[sym], LIT_BITS[sym])
            if LENGTH_EXTRA[li] > 0 then
                w:put(best_len - LENGTH_BASE[li], LENGTH_EXTRA[li])
            end

            local di = dist_index(best_dist)
            w:put(DIST_CODE[di - 1], 5)
            if DIST_EXTRA[di] > 0 then
                w:put(best_dist - DIST_BASE[di], DIST_EXTRA[di])
            end

            -- Register the positions the match skipped so later matches can still
            -- find them.
            for k = pos + 1, pos + best_len - 1 do
                if k + MIN_MATCH - 1 <= n then
                    local h2 = hash3(data, k)
                    prev[k] = head[h2]
                    head[h2] = k
                end
            end
            pos = pos + best_len
        else
            local literal = byte(data, pos)
            w:put(LIT_CODE[literal], LIT_BITS[literal])
            pos = pos + 1
        end
    end

    w:put(LIT_CODE[256], LIT_BITS[256]) -- end of block
    w:align()
end

--- Emits `data` as uncompressed stored blocks.
local function deflate_stored(data, w)
    local n = #data
    local pos = 1
    repeat
        local chunk = n - pos + 1
        if chunk > 65535 then
            chunk = 65535
        end
        local final = (pos + chunk - 1 >= n) and 1 or 0

        w:put(final, 1)
        w:put(0, 2) -- BTYPE = 00, stored
        w:raw(
            char(
                chunk % 256,
                floor(chunk / 256),
                (65535 - chunk) % 256,
                floor((65535 - chunk) / 256)
            )
        )
        w.out[#w.out + 1] = sub(data, pos, pos + chunk - 1)

        pos = pos + chunk
    until pos > n
end

local HEADER = '\031\139\008\000\000\000\000\000\000\003'

--- Compresses `data` into one complete gzip member.
---
--- @param data string
--- @return string member Concatenate members to build a valid `.gz`.
function M.compress(data)
    local w = new_writer()
    deflate_fixed(data, w)
    local body = concat(w.out)

    -- Stored framing costs 5 bytes per 64KiB block. If the Huffman-coded body did
    -- not beat that, ship the bytes uncompressed instead.
    if #body >= #data + 5 then
        local stored = new_writer()
        deflate_stored(data, stored)
        body = concat(stored.out)
    end

    return HEADER .. body .. le32(crc32(data)) .. le32(#data)
end

M._crc32 = crc32

return M
