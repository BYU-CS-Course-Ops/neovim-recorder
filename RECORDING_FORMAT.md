# Recording Schema

This repository emits the shared recording schema consumed by
`code_recorder_processor` / [`recan`](https://github.com/BYU-CS-Course-Ops/code-recording-analysis),
alongside the [VS Code](https://github.com/BYU-CS-Course-Ops/vs-code-recorder)
and [JetBrains](https://github.com/BYU-CS-Course-Ops/jetbrains-recorder)
recorders.

## File Format

- Filename: `{basename}.recording.jsonl.gz`
- Location: adjacent to the recorded source file
- Encoding: gzip-compressed UTF-8 JSON Lines

Each flushed batch is appended as its own gzip member, matching the other two
recorders. Decoders read concatenated members as a single stream, so a crash
costs at most the last unflushed batch rather than the whole recording.

## Tracked Files

The recorder only records a whitelisted set of file extensions, mirroring the
JetBrains and VS Code recorders. Files of any other type are ignored even while
open. The current whitelist is:

- `.py`
- `.h`, `.hpp`, `.cpp`
- `.java`

## Deferred Recording

A recording file is **not** created merely because a file is open. When a file is
opened (or recording starts), its initial snapshot is held in memory. The
`.recording.jsonl.gz` file is created — and the buffered snapshot written ahead
of the first edit — only once that file receives a real edit. Files that are
opened but never edited produce no recording at all.

## Edit Event

```json
{
  "type": "edit",
  "editor": "neovim",
  "recorderVersion": "2026.9.1",
  "timestamp": "2026-09-04T04:07:00.902Z",
  "document": "/absolute/path/to/file.py",
  "offset": 42,
  "oldFragment": "deleted text here",
  "newFragment": "inserted text here"
}
```

Required fields:

- `type`
- `timestamp`
- `document`
- `offset`
- `oldFragment`
- `newFragment`

Recorder metadata:

- `editor`
- `recorderVersion`

## Snapshot Event

Snapshots are encoded as edit events with:

- `offset = 0`
- `oldFragment === newFragment`

The recorder emits a snapshot instead of a delta when replaying its own delta
against its tracked buffer state does not reproduce the buffer.

## Status Event

```json
{
  "type": "focusStatus",
  "editor": "neovim",
  "recorderVersion": "2026.9.1",
  "timestamp": "2026-09-04T04:07:00.902Z",
  "focused": true
}
```

Focus events are written immediately to every actively recording file, and
depend on the terminal reporting focus. Most modern terminals do; a few older
ones never send focus events, in which case no `focusStatus` lines appear and the
analyser treats the session as continuously focused.

## Neovim-Specific Normalisation

Neovim's buffer model differs from the VS Code and JetBrains document models in
three ways that are visible in the recorded text. All three are deliberate.

### Offsets count codepoints

`offset` is a **codepoint** offset into the document. The VS Code and JetBrains
recorders emit UTF-16 code-unit offsets, which are identical for every character
in the Basic Multilingual Plane and diverge only for astral characters such as
emoji. `recan` splices fragments into a Python `str`, which is indexed by
codepoint, so codepoint offsets are what the analyser actually consumes.

### Line endings are normalised to LF

Neovim buffer lines never carry a `\r`, so a CRLF file is recorded as though it
used LF. Offsets stay internally consistent, which is what replay requires.

### The document always ends with a newline

Neovim counts a trailing newline in every byte offset it reports, even for a
buffer with `'nofixeol'` where that newline is never written to disk. The
recorded document text therefore always ends with `\n`.

## Compatibility

Older recordings may omit `recorderVersion`. The processor remains compatible
with those files.

## Events This Recorder Does Not Emit

The VS Code recorder additionally emits a `fileSwitch` event. It is deliberately
omitted here: it is absent from the JetBrains `RECORDING_FORMAT.md`, the two
implementations disagree on its field names (`from`/`to` versus `left`/
`arrived`), and `recan` currently ignores the event type. If it is standardised
later, `recorder.queue_status_event('fileSwitch', { { 'from', a }, { 'to', b } })`
is all that is needed to add it.
