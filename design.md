# Design

## Doc listener

`nvim_buf_attach` `on_bytes` -> queue
Batch processor: queue -> batcher -> writer

Batch by:

- Document (flush if different document)
- Timestamp (flush after idle for 1 second)

The writer appends a new GZIP member for each batch.

The output location is adjacent to the observed file: an edit in `program.py` is
written to `program.recording.jsonl.gz`.

## Strategy

Avoid module-level mutable state where reasonable. Try to maintain a more
functional design.

The goal is to keep the code simple and easy to reason about, and to keep the
three recorders structurally recognisable to anyone who has read one of the
others.

## Neovim Plugin Architecture

- `plugin/code_recorder.lua` — bootstrap; applies defaults if nothing calls `setup`
- `lua/code-recorder/init.lua` — entry point, commands, cross-session state
- `lua/code-recorder/recorder.lua` — recording engine, change capture, batching
- `lua/code-recorder/writer.lua` — event serialisation and gzip framing
- `lua/code-recorder/gzip.lua` — dependency-free DEFLATE encoder
- `lua/code-recorder/status.lua` — statusline component
- `lua/code-recorder/detector.lua` — resume prompt for existing recordings
- `lua/code-recorder/config.lua` — defaults and user options
- `lua/code-recorder/log.lua` — diagnostic log

## Why a shadow copy of each buffer

The schema wants `offset`, `oldFragment`, and `newFragment` for every change.
VS Code hands all three to its listener. Neovim's `on_bytes` reports *where* a
change happened and how many bytes it replaced, but never what was replaced —
by the time the callback fires the old text is gone.

So the recorder keeps a shadow copy of every tracked buffer. The shadow supplies
`oldFragment`; the buffer supplies `newFragment`. After each change the recorder
replays its own delta against the shadow and compares the result to the buffer.
If they differ, the delta is not trustworthy and a full snapshot is emitted
instead — the escape hatch the shared schema already documents. That comparison
is the same per-change full-document check the VS Code and JetBrains recorders
perform, so the cost profile matches theirs.

Both fragments are sliced out of full document text by byte offset rather than
derived from `on_bytes`'s row/column arguments. A change that ends on the
buffer's implicit final newline is not addressable by `nvim_buf_get_text`, and
byte slicing sidesteps that case entirely.

## Why the plugin carries a DEFLATE encoder

Neovim exposes no zlib binding, and a `gzip` binary cannot be assumed on a
student's machine — particularly on Windows. Shelling out would make recording
depend on the student's `PATH`.

`gzip.lua` is therefore a self-contained encoder: fixed-Huffman DEFLATE
(RFC 1951 §3.2.6) over greedy LZ77 matches, with a stored-block fallback when
compression would not pay for itself. It compresses the recorder's own output —
long runs of near-identical JSON — by roughly 15–45x.

Each `compress` call returns one complete gzip member. Appending members yields a
valid `.gz`; Python's `gzip` module decodes the concatenation as a single stream.

## Deferred recording

An initial snapshot is queued when a file is opened but held in memory rather
than written. Only when that document receives a real edit is its output path
registered and the buffered snapshot flushed ahead of the first delta. A file
that is opened and never touched leaves no recording behind, and status events
are never written to it.

## Testing

`tests/run.lua` is a self-contained runner — no busted or plenary — so the suite
runs anywhere the plugin does. It stubs `writer.append` and asserts on JSON
lines, including replaying each recording back into the document the buffer
actually held.

That cannot prove the bytes on disk are valid gzip, because nothing in Lua
decompresses them. `tests/e2e.lua` therefore drives a real session to disk and
`tests/verify_e2e.py` decodes it with Python's `gzip` and replays it with
`recan`'s splice semantics. Both run in CI.
