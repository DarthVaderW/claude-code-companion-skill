# cc-watch Runtime Issues

This is a lightweight backlog for rough edges observed while using `cc-watch`
from Codex. Keep it factual and do not store secrets, tokens, raw environment
dumps, personal paths, or full Claude stream logs here.

## Current Status

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

In progress after `v0.3.0`:

- Local job titles with `--title`.
- `transcript.md` as a readable prompt/result view for future Codex threads.
- `list`, `show`, and `resume` commands for project-local Claude collaboration
  threads.

## Still Open

1. Extract and show a small "last assistant text before failure" excerpt when a
   job fails before a final result event.
2. Summarize denied tool requests as first-class warnings in `metadata.md` and
   `result.txt`.
3. Add a lightweight `doctor` or `status` hint when the caller repository does
   not ignore `.cc-watch/`.
4. Add job management helpers such as `prune` or `archive`.
5. Consider an optional heartbeat for long foreground `run` jobs so Codex can
   distinguish slow progress from silence.
6. Document the release and install/update path for GitHub-tagged skill
   installs separately from local symlink development installs.

## Origin

This backlog came from a read-only Claude Code review workflow where a long
Opus job produced useful partial text but then ended with an API/socket failure.
The main design lesson is that every terminal job needs a durable, readable
archive, even when Claude does not emit a clean final result.
