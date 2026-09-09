# BYU CS Code Recorder for Neovim

Records code changes as students work, without recording their screen. Every
edit to a whitelisted source file is written to `{basename}.recording.jsonl.gz`
beside the file, in the schema shared with the
[VS Code](https://github.com/BYU-CS-Course-Ops/vs-code-recorder) and
[JetBrains](https://github.com/BYU-CS-Course-Ops/jetbrains-recorder) recorders
and read by
[`recan`](https://github.com/BYU-CS-Course-Ops/code-recording-analysis).

Requires Neovim 0.10 or newer. No external dependencies — not even a `gzip`
binary; the plugin carries its own DEFLATE encoder.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    'BYU-CS-Course-Ops/neovim-recorder',
    opts = {},
}
```

With [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use({
    'BYU-CS-Course-Ops/neovim-recorder',
    config = function()
        require('code-recorder').setup()
    end,
})
```

Or drop the repository anywhere on your `runtimepath`. Calling `setup()` is
optional: if the editor starts and nothing has configured the plugin, it applies
the defaults on its own, so a student can install it and forget it.

## Usage

| Command                | Description                                     |
|------------------------|-------------------------------------------------|
| `:CodeRecorderStart`   | Start recording.                                |
| `:CodeRecorderStop`    | Stop recording and flush everything to disk.    |
| `:CodeRecorderToggle`  | Toggle recording.                               |
| `:CodeRecorderStatus`  | Report what is being recorded, and where.       |
| `:CodeRecorderFlush`   | Force a flush without stopping.                 |
| `:CodeRecorderLog`     | Open the recorder's diagnostic log.             |

Recording state persists across restarts: if Neovim exits while recording, the
next session resumes automatically. If you open a file that already has a
recording beside it while the recorder is stopped, you are asked once whether to
resume.

The same functions are available from Lua:

```lua
local recorder = require('code-recorder')
recorder.start()
recorder.stop()
recorder.toggle()
recorder.is_recording()
recorder.status()
```

## Statusline

`require('code-recorder').statusline()` returns `REC`, `REC*` (flashing as edits
are captured), or `REC off`.

```lua
vim.o.statusline = "%f %=%{v:lua.require'code-recorder'.statusline()}"
```

With lualine:

```lua
require('lualine').setup({
    sections = {
        lualine_x = {
            {
                function() return require('code-recorder').statusline() end,
                color = function() return require('code-recorder.status').highlight() end,
            },
        },
    },
})
```

The highlight groups `CodeRecorderActive`, `CodeRecorderInactive`, and
`CodeRecorderFlash` are defined with `default = true`, so your colorscheme can
override them.

## Configuration

Defaults shown:

```lua
require('code-recorder').setup({
    -- File extensions eligible for recording. Matches the VS Code and
    -- JetBrains whitelists.
    tracked_extensions = { '.py', '.h', '.hpp', '.cpp', '.java' },

    -- Idle time before a batch of edits is flushed to disk.
    batch_idle_ms = 1000,

    -- Start recording on startup regardless of what the last session did.
    auto_start = false,

    -- Resume if the previous session was recording when it exited.
    resume_previous_session = true,

    -- What to do when a file with an existing recording is opened while
    -- stopped: 'select' asks, 'notify' just mentions it, false does nothing.
    resume_prompt = 'select',

    -- Directories recording is confined to. nil means the current working
    -- directory, refreshed on :cd.
    roots = nil,

    -- Show a notification when recording starts and stops.
    notify = true,

    -- Minimum level written to the recorder log.
    log_level = vim.log.levels.INFO,
})
```

## What gets recorded

Only files that are **all** of:

- under one of the workspace roots,
- carrying a whitelisted extension,
- backed by a real file (not a terminal, help page, or other special buffer),

and only once they have actually been edited. Opening a file and never touching
it produces no recording at all.

The recorder captures every buffer change — typing, pastes, undo, redo, LSP code
actions, formatter runs, macros, and edits made by other plugins — because it
attaches at the buffer level rather than watching keystrokes.

See [RECORDING_FORMAT.md](RECORDING_FORMAT.md) for the event schema and the
Neovim-specific normalisations.

## Development

```bash
nvim -l tests/run.lua          # unit and integration suite
nvim -l tests/lint.lua         # every Lua file loads
nvim -l tests/e2e.lua out      # write a real recording to ./out
python tests/verify_e2e.py out # decode it and replay it the way recan does
```

The Lua suite stubs the writer so it can assert on JSON lines. `verify_e2e.py`
is the step that proves the bytes on disk are valid gzip and that the edit stream
replays back to the document the editor actually held.

See [design.md](design.md) for the architecture and
[AGENTS.md](AGENTS.md) for contribution conventions.

## License

MIT. See [LICENSE](LICENSE).
