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

1. Add more `doctor` guidance for custom state roots if real-world usage shows
   confusing archive locations.
2. Consider an optional heartbeat for long foreground `run` jobs so Codex can
   distinguish slow progress from silence.
3. Add a cleanup path for stale `running-*` jobs whose worker process has
   already died; current prune/archive intentionally skip raw non-terminal
   status files.
4. Document the release and install/update path for GitHub-tagged skill
   installs separately from local symlink development installs.
5. Keep mutating Claude plugin operations out of `cc-watch`. If a future
   `cc-plugin update` is added, it must require explicit plugin names, `--yes`,
   and a clear warning that it writes global `~/.claude` plugin state.
6. Defer MCP smoke checks until there is an explicit read-only MCP allowlist and
   a proven need. Prompt text alone is not a write guard.

## Origin

This backlog came from a read-only Claude Code review workflow where a long
Opus job produced useful partial text but then ended with an API/socket failure.
The main design lesson is that every terminal job needs a durable, readable
archive, even when Claude does not emit a clean final result.
