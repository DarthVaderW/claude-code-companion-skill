# cc-watch Runtime Issues

This is a lightweight backlog for rough edges observed while using `cc-watch`
from Codex. Keep it factual and do not store secrets, tokens, raw environment
dumps, personal paths, or full Claude stream logs here.

## Current Status

Resolved after `v0.3.0`:

- Local job titles, `transcript.md`, `list`, `show`, and `resume` were shipped
  in `v0.4.0`.
- Human-readable `cc-watch` outputs now apply best-effort redaction for
  secret-shaped strings. Raw `stdout.jsonl` remains local lossless evidence.
- `cc-watch` supports `--state-root` with an explicit
  `--allow-external-state-root` guard for archives outside `--cwd`.
- Custom state roots are nested under `DIR/.cc-watch/` so the helper does not
  write a catch-all `.gitignore` into a user-owned parent directory.
- `cc-plugin` was added as a read-only sibling for Claude Code plugin
  `doctor`, `list`, `versions`, and dry-run `plan-update` checks.
- Failed jobs now surface denied/disallowed tool warnings and the last
  assistant text seen before a missing final result.
- `cc-watch archive` and `cc-watch prune` were added with dry-run defaults and
  explicit `--yes` for actual cleanup.
- Strict plan-review and diff-review hooks are documented for rigorous projects
  and long-running `/goals` style workflows.
- Foreground `cc-watch run` and `resume` now support `--heartbeat SEC` so Codex
  can see compact progress during long Claude calls without reading raw
  `stream-json`.
- `cc-watch` now supports repeatable `--mcp-tool TOOL`, which loads configured
  MCP servers, keeps built-in `--tools` narrowed, enables `ToolSearch` for lazy
  discovery, and passes expanded MCP names through `--allowedTools`.
- `cc-watch repair-stale` provides a dry-run-first cleanup path for old
  non-terminal jobs whose worker, Claude, and watchdog processes have all died.
  It marks them `failed` and writes a readable result archive; it does not
  delete directories or kill processes.
- `cc-watch doctor` now reports the helper version, state-root placement, stale
  job counts, and a dry-run repair command for repairable stale jobs.
- The README now separates local symlink development installs from stable
  GitHub-tagged skill installs and updates.
- `cc-watch --mcp-tool` now expands `siyuan_*` and `zotero_*` short aliases to
  the user's Claude Code plugin-prefixed MCP tool names, rejects other bare
  names before Claude starts, and records both requested and effective tool
  names in job metadata.
- `cc-watch --mcp-tool` no longer puts MCP names in Claude's built-in `--tools`
  flag. Plugin MCP servers may still appear as `pending` in the init stream;
  that is healthy when `ToolSearch` later discovers and calls the allowlisted
  tool.

Resolved in `v0.3.0`:

- Terminal jobs now archive `result.txt`, `metadata.json`, `metadata.md`,
  `prompt.md`, `stdout.jsonl`, and `stderr.log`.
- Failed, timed-out, and canceled jobs now produce a readable `result.txt`
  instead of requiring raw stream inspection.
- `cc-watch result` prints the archived result for every terminal job and exits
  non-zero for failed, timed-out, or canceled jobs.
- `cc-watch cancel` finalizes an archive.
- `cc-watch status` returns zero for running jobs by default; scripts can opt
  into polling-style behavior with `--strict-exit`.
- Long prompts can be passed with `--prompt-file`.
- The README and skill now recommend narrow, pasted-diff prompts when broad
  Opus reviews are slow or unreliable.
- This repository ignores `.cc-watch/` job directories.

## Still Open

1. Keep mutating Claude plugin operations out of `cc-watch`. If a future
   `cc-plugin update` is added, it must require explicit plugin names, `--yes`,
   and a clear warning that it writes global `~/.claude` plugin state.
2. Add real MCP smoke-check examples only after exact read-only SiYuan/Zotero
   tool names are stable across the user's Claude Code installs. Prompt text
   alone is not a write guard.
3. Investigate whether Claude Code exposes a reliable pre-prompt readiness
   signal for plugin MCP servers. For now, `pending` plugin servers should be
   treated as readiness lag; failure is only when `ToolSearch` cannot discover
   the allowlisted tool or Claude reports an actual permission denial.

## Origin

This backlog came from a read-only Claude Code review workflow where a long
Opus job produced useful partial text but then ended with an API/socket failure.
The main design lesson is that every terminal job needs a durable, readable
archive, even when Claude does not emit a clean final result.
