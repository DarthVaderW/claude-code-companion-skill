# Changelog

## Unreleased

- Add failure diagnostics to `cc-watch` archives: denied/disallowed tool
  warnings and the last assistant text seen before a missing final result.
- Add best-effort redaction for human-readable `cc-watch` outputs while keeping
  raw `stdout.jsonl` as local lossless evidence.
- Add `--state-root` and `--allow-external-state-root` so archives can be stored
  outside the target project without writing a catch-all `.gitignore` into the
  user-selected parent directory.
- Add read-only sibling helper `cc-plugin` for Claude Code plugin `doctor`,
  `list`, `versions`, and dry-run `plan-update` checks.
- Add fake-Claude regression tests for redaction, custom state roots, external
  state-root guards, and read-only plugin admin behavior.

## v0.4.0 - 2026-06-06

- Add local job titles with `--title TITLE`; titles are stored in cc-watch
  state and are not passed to Claude.
- Add `transcript.md` for terminal jobs so Codex, CLI users, and future threads
  can read a compact prompt/result record without opening raw stream JSON.
- Add `cc-watch list` to enumerate project-local jobs from `.cc-watch/`.
- Add `cc-watch show` to read the latest job, a job id, or the most recent
  matching title as `result.txt`, `transcript.md`, `metadata.json`, or raw
  `stdout.jsonl`.
- Add `cc-watch resume JOB_ID_OR_TITLE_OR_SESSION_ID -- PROMPT`; job/title
  selectors require a persisted Claude session and fail clearly for default
  non-persistent jobs.
## v0.3.0 - 2026-06-06

- Add durable result archives for every terminal job:
  - `result.txt` as the human-readable entry point
  - `metadata.json` and `metadata.md` for job metadata
  - stderr and stream tails in failed, timed-out, and canceled results
- Add `--prompt-file FILE` for long Markdown prompts.
- Add `--strict-exit` for `status`.
- Change default `status` exit behavior: `running-active` and `running-quiet`
  now return zero unless `--strict-exit` is passed. Existing polling scripts
  that expect running jobs to return non-zero should add `--strict-exit`.
- Make `result` print `result.txt` for any terminal job and exit non-zero for
  failed, timed-out, or canceled jobs.
- Keep foreground `run` and later `result` exit codes consistent for non-zero
  Claude exits.
- Add regression coverage for failed, timed-out, and canceled result archives,
  metadata JSON validity, relative `--prompt-file` resolution, and exact
  non-zero exit propagation.
- Document observed runtime issues and follow-up work in
  `CC_WATCH_RUNTIME_ISSUES.md`.

## v0.2.1 - 2026-06-05

- Improve long-running job ergonomics:
  - show elapsed seconds in `status`
  - add `--max-runtime SEC` for `run`/`start`
  - make async startup failures leave a clear final state
  - keep async workers alive when the parent shell exits
  - make cancel/timeout target the actual Claude process
  - make `cancel` and timeout status transitions deterministic
  - keep `status` observational instead of using it to kill jobs
  - show `status=timed-out` in foreground `run` output when a timeout fires
  - record terminal elapsed time instead of letting elapsed grow forever
- Document that Codex tool calls should prefer foreground `run` unless the
  shell remains alive for async polling.
- Expand fake-Claude regression tests for `start/status/result/cancel`.
- Remove an unused `readonly` state file to simplify job metadata.

## v0.2.0 - 2026-06-05

- Hardened default read-only behavior:
  - default tools are restricted to local read tools
  - MCP config is disabled by default
  - `--allow-bash`, `--allow-mcp`, and `--read-write` are explicit opt-ins
- Added `cc-watch doctor` for local CLI/auth/proxy/path preflight without
  making a model request or printing secrets.
- Added `agents/openai.yaml` skill metadata.
- Added `.gitignore` handling for `.cc-watch/` so prompts and raw stream logs
  are not committed by accident.
- Added fake-Claude regression tests.
- Treated `stream-json` final error events as failures instead of successful
  completions.

## v0.1.0 - 2026-06-05

- Published the minimal Codex skill shape:
  - `claude-code-companion/SKILL.md`
  - `claude-code-companion/scripts/cc-watch`
- Added explicit Claude session controls:
  - `--persist-session`
  - `--resume SESSION_ID`
  - `--continue`
- Kept the project as a Codex skill, not a plugin, MCP server, Python package,
  or `uvx` tool.
