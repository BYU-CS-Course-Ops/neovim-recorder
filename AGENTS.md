# Repository Guidelines

## Project Structure & Module Organization
- `lua/code-recorder/` holds the plugin modules: `init.lua` (entry point and commands), `recorder.lua` (core recording logic), `writer.lua` (serialisation and gzip framing), `gzip.lua` (DEFLATE encoder), plus `config.lua`, `status.lua`, `detector.lua`, and `log.lua`.
- `plugin/code_recorder.lua` is the bootstrap Neovim sources automatically; keep it thin and defer everything to `setup()`.
- `tests/` holds the runner (`run.lua`), the `*_spec.lua` suites, and the end-to-end pair (`e2e.lua` + `verify_e2e.py`).
- `doc/code-recorder.txt` is the `:help` documentation; regenerate tags with `:helptags doc/` after editing it.

## Build, Test, and Development Commands
- `nvim -l tests/run.lua` runs the whole Lua suite; pass spec names (`nvim -l tests/run.lua writer_spec`) to narrow it.
- `nvim -l tests/lint.lua` checks that every Lua file loads.
- `nvim -l tests/e2e.lua tests/.out` writes a real recording, and `python tests/verify_e2e.py tests/.out` decodes and replays it.
- `stylua lua plugin tests` applies the formatting CI enforces.

## Coding Style & Naming Conventions
- Lua targets Neovim 0.10+; use four-space indentation, single-quoted strings, and `snake_case` for functions and locals.
- Prefix module-private helpers with `local`; expose test seams as `M._name` so the public surface stays obvious.
- Add LuaCATS annotations (`--- @param`, `--- @return`) for public functions and comment any non-obvious platform behaviour.

## Testing Guidelines
- Place tests in `tests/`, one `*_spec.lua` per module, and register new specs in the `specs` list in `tests/run.lua`.
- Add a regression test whenever recording behaviour, the event schema, or command registration changes.
- Changes to `gzip.lua` or `writer.lua` must keep `tests/verify_e2e.py` passing; it is the only check that reads the bytes an analyst actually receives.

## Commit & Pull Request Guidelines
- Craft imperative, present-tense commit subjects under ~65 characters (e.g., `Add focus status tracking`).
- Reference issues in the footer (`Refs #123`) and isolate commits to single concerns.
- Pull requests should summarize behavior changes, list manual verification steps, and link to relevant specs.

## Recording Output Format
- Changes are written to `{filename}.recording.jsonl.gz` adjacent to the source file.
- Each line is a JSON object with `type`, `timestamp`, `document`, `offset`, `oldFragment`, and `newFragment` fields.
- Status events (e.g. focus changes) are written to all active recording files.
- The schema is shared with the VS Code and JetBrains recorders; see `RECORDING_FORMAT.md` before changing it, and change it in all three repositories together.
