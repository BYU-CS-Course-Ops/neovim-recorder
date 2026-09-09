--- Serialisation and on-disk framing for recordings.
---
--- Every batch handed to `append` becomes one gzip member appended to the
--- recording file. That matches the VS Code and JetBrains recorders, which also
--- append an independent member per flush rather than holding a single stream
--- open for the life of the session; a crash therefore costs at most the last
--- unflushed batch instead of the whole file.

local gzip = require('code-recorder.gzip')
local RECORDER_VERSION = require('code-recorder.version')

local M = {}

local EDITOR = 'neovim'
local RECORDING_SUFFIX = '.recording.jsonl.gz'

M.RECORDING_SUFFIX = RECORDING_SUFFIX
M.EDITOR = EDITOR

--- Computes the recording path that sits alongside `source`.
---
--- The final extension is replaced, so `hw/prog.py` records to
--- `hw/prog.recording.jsonl.gz`. A dotfile with no extension keeps its whole
--- name, matching the reference recorders.
---
--- @param source string Absolute path to the recorded source file.
--- @return string
function M.recording_path(source)
    local sep_idx = source:find('[/\\][^/\\]*$')
    local dir = sep_idx and source:sub(1, sep_idx) or ''
    local name = sep_idx and source:sub(sep_idx + 1) or source
    local stem = name:match('^(.+)%.[^.]*$') or name
    return dir .. stem .. RECORDING_SUFFIX
end

--- Reports whether `path` is itself a recording file.
--- @param path string
--- @return boolean
function M.is_recording_file(path)
    return path:find(RECORDING_SUFFIX, 1, true) ~= nil
end

--- Renders an ISO-8601 UTC timestamp with millisecond precision.
---
--- Matches the VS Code recorder's `Date.toISOString()`; `recan.parse_ts` accepts
--- this and trims anything finer.
--- @return string
function M.timestamp()
    local seconds, microseconds = vim.uv.gettimeofday()
    return os.date('!%Y-%m-%dT%H:%M:%S', seconds)
        .. string.format('.%03dZ', math.floor(microseconds / 1000))
end

--- JSON-encodes a single value.
local function encode(value)
    return vim.json.encode(value)
end

--- Serialises an edit event.
---
--- Keys are emitted in the order the shared schema documents them rather than in
--- whatever order a Lua table happens to iterate, so recordings from all three
--- editors diff cleanly against each other.
---
--- @param event table `{ timestamp, document, offset, old_fragment, new_fragment }`
--- @return string
function M.encode_edit(event)
    return table.concat({
        '{"type":"edit"',
        ',"editor":',
        encode(EDITOR),
        ',"recorderVersion":',
        encode(RECORDER_VERSION),
        ',"timestamp":',
        encode(event.timestamp),
        ',"document":',
        encode(event.document),
        ',"offset":',
        tostring(event.offset),
        ',"oldFragment":',
        encode(event.old_fragment),
        ',"newFragment":',
        encode(event.new_fragment),
        '}',
    })
end

--- Serialises a status event such as `focusStatus`.
---
--- @param status_type string
--- @param timestamp string
--- @param fields table[] Ordered `{ key, value }` pairs appended after the header.
--- @return string
function M.encode_status(status_type, timestamp, fields)
    local parts = {
        '{"type":',
        encode(status_type),
        ',"editor":',
        encode(EDITOR),
        ',"recorderVersion":',
        encode(RECORDER_VERSION),
        ',"timestamp":',
        encode(timestamp),
    }
    for _, pair in ipairs(fields or {}) do
        parts[#parts + 1] = ',' .. encode(pair[1]) .. ':' .. encode(pair[2])
    end
    parts[#parts + 1] = '}'
    return table.concat(parts)
end

--- Appends JSON lines to `path` as one gzip member.
---
--- @param path string
--- @param lines string[]
--- @return boolean ok
--- @return string|nil err
function M.append(path, lines)
    if #lines == 0 then
        return true
    end

    local payload = table.concat(lines, '\n') .. '\n'
    local member = gzip.compress(payload)

    -- Binary append is mandatory: on Windows text mode would rewrite \n as \r\n
    -- inside the compressed bytes and corrupt the member.
    local handle, err = io.open(path, 'ab')
    if not handle then
        return false, err or ('could not open ' .. path)
    end

    local ok, write_err = pcall(function()
        handle:write(member)
    end)
    handle:close()

    if not ok then
        return false, tostring(write_err)
    end
    return true
end

return M
