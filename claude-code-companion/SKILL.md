---
name: claude-code-companion
description: Use Claude Code as a second reviewer or research collaborator while keeping Codex in control. Prefer this when a task benefits from independent review, long-context code inspection, adversarial critique, or parallel research, especially when Claude Code may run slowly and raw stream-json should not enter Codex context.
---

# Claude Code Companion

Use this skill when Claude Code should help Codex think, review, or investigate.
Claude is a collaborator, not the owner of the task. Codex remains responsible
for validating the result before changing files or answering the user.

## When To Call Claude

Call Claude Code when at least one of these is true:

- A code review needs an independent second opinion.
- A design or implementation plan needs adversarial critique.
- A repository has enough context that another long-context pass may catch
  missed issues.
- A research task can be split so Codex and Claude investigate in parallel.
- Claude may take a long time, and Codex needs a reliable way to wait, poll, and
  retrieve the archived result without reading raw stream-json.

Do not call Claude for tiny tasks where Codex can answer directly.

## Default Collaboration Rules

- Send Claude a Markdown prompt, not a JSON request protocol.
- Include `cwd`, branch/base, task goal, constraints, relevant commands, and
  what output you need.
- Default to highest effort unless the user asks for a faster pass.
- Treat Claude as read-only by default. The helper allows only local read tools
  by default and disables MCP config unless `--allow-mcp` is explicit.
- Prefer explicit MCP tool allowlists over broad MCP access. Use repeatable
  `--mcp-tool TOOL` for known read-only SiYuan/Zotero tools; it implies MCP
  config loading but keeps `--tools` narrow.
- Prefer passing diffs, file lists, or command output in the prompt. Use
  `--allow-bash` only when Claude genuinely needs shell access.
- For long prompts, write a Markdown prompt file and pass `--prompt-file`.
- Use `--read-write` only when the user explicitly asks Claude Code to take over
  edits. Codex should normally remain the writer.
- Use the helper's default fresh non-persistent print-mode session for one-off
  reviews. Pass `--persist-session` when a new Claude session should be
  resumable, `--resume <session-id>` to continue a known session, or
  `--continue` only when continuing Claude's latest cwd session is intended.
- For a long task or `/goals` run, start one persisted Claude thread with a
  stable title, then prefer `cc-watch resume <title>` for subsequent plan,
  research, MCP-reading, and diff-review prompts so Claude keeps context.
- Do not let Claude and Codex edit the same files at the same time unless the
  user explicitly asks for a handoff.
- Do not expose secrets. Never ask Claude to print env values. If env checking
  is needed, only allow `KEY=unset` or `KEY=REDACTED`.
- Remember that Claude Code may receive default CLI/project context even when
  the prompt says not to read files. Treat its answer as informed by that
  context unless the command runs in a deliberately isolated directory.
- Codex must independently inspect and verify Claude's findings before acting.

## How To Run

The helper script is in this skill:

```bash
scripts/cc-watch
```

For short synchronous work:

```bash
scripts/cc-watch run --cwd . --title release-review -- "Review the current diff. Return only actionable findings."
```

For a standard read-only diff review, prefer the built-in prompt builder:

```bash
scripts/cc-watch review-diff --cwd . --base origin/main --title release-review
```

`review-diff` builds the prompt from tracked git changes and then uses the
normal foreground `run` path. It includes committed, staged, and unstaged
tracked diffs, records the base ref in metadata, and sends that raw diff to
Claude. It intentionally does not embed untracked file contents. Use
`--max-diff-bytes N` for very large diffs.

For long prompts:

```bash
scripts/cc-watch run --cwd . --prompt-file review.md
```

Relative `--prompt-file` paths resolve from the shell invocation directory, not
from `--cwd`.

Before diagnosing auth, proxy, PATH, or CLI flag issues:

```bash
scripts/cc-watch doctor --cwd .
```

For resumable work:

```bash
scripts/cc-watch run --persist-session --cwd . --title repo-review -- "Start a reusable review thread."
scripts/cc-watch resume --cwd . repo-review -- "Continue that review."
scripts/cc-watch resume --cwd . <job-id> -- "Continue by job id."
scripts/cc-watch resume --cwd . <session-id> -- "Continue by raw Claude session id."
```

Default jobs use `--no-session-persistence` and are not resumable. Use
`--persist-session` for any Claude thread that may need a later continuation.

For long work from a persistent terminal or one shell script:

```bash
job_id="$(scripts/cc-watch start --cwd . -- "Investigate this repo and report risks.")"
scripts/cc-watch status "$job_id"
scripts/cc-watch result "$job_id"
scripts/cc-watch list --cwd .
scripts/cc-watch show --cwd . --last
scripts/cc-watch show --cwd . repo-review --transcript
```

To keep archives outside the target repo, pass the same state root to every
command that should read or write that job. If the state root is outside
`--cwd`, repeat `--allow-external-state-root` on read commands too:

```bash
scripts/cc-watch run --cwd . --state-root /path/to/reviews --allow-external-state-root -- "Review this repo."
scripts/cc-watch result <job-id> --cwd . --state-root /path/to/reviews --allow-external-state-root
```

When running inside Codex tool calls, prefer foreground `run` unless the shell
will remain alive; some command runners clean background children when the tool
call exits. Use `status` while waiting. `running-quiet` means Claude is still
alive but has not emitted stream-json recently; do not treat it as failure. Use
`--max-runtime SEC` to bound long Opus jobs when needed. Use
`--heartbeat SEC` for long foreground calls when Codex should see compact
progress without reading raw `stream-json`.

For a persistent long-task reviewer:

```bash
scripts/cc-watch run --persist-session --cwd . --title goal-review --heartbeat 60 -- "Start the review thread..."
scripts/cc-watch resume --cwd . goal-review --heartbeat 60 -- "Continue with the latest diff..."
```

Every terminal job writes `.cc-watch/<job-id>/result.txt`, `transcript.md`,
`metadata.json`, `metadata.md`, `prompt.md`, `stdout.jsonl`, and `stderr.log`.
Treat `result.txt` as the human-readable archive entry, `transcript.md` as the
prompt-plus-answer view for future reading, and `stdout.jsonl` as the local
lossless raw evidence. Human-readable outputs are best-effort redacted for
secret-shaped strings; do not rely on redaction as a reason to enable MCP or
print environment values. Failed jobs include denied/disallowed tool warnings
and the last assistant text before failure when available. `result` prints
`result.txt` for any terminal job and exits non-zero for failed, timed-out, or
canceled jobs. `status` returns zero for running jobs by default; use
`--strict-exit` only when a script needs polling-style non-zero exits.
Use `result --json` when Codex needs the metadata and final answer in one
machine-readable object while preserving the same exit-code contract.
Use `list --json` when Codex needs a newest-first machine-readable index of
local jobs, including status, session resumability, timing, and archive paths.
Use `findings` or `findings --json` when Codex needs a compact, section-based
view of the review result without loading the full transcript:

```bash
scripts/cc-watch findings --cwd . --last
scripts/cc-watch findings --cwd . repo-review --json
```

For Claude Code plugin inspection, use the read-only sibling helper:

```bash
scripts/cc-plugin doctor --cwd .
scripts/cc-plugin list --cwd .
scripts/cc-plugin versions --cwd .
scripts/cc-plugin plan-update --cwd . --plugin siyuan-mcp
```

`cc-plugin` does not update marketplace metadata or plugins. Treat any command
that would run `claude plugin marketplace update` or `claude plugin update` as a
separate global-state mutation requiring explicit user approval.
If `claude plugin versions` is unavailable, `cc-plugin versions` falls back to
the installed-version view from `claude plugin list`.

For local job cleanup, use dry-run-first archive/prune commands:

```bash
scripts/cc-watch archive --cwd . --keep 10
scripts/cc-watch archive --cwd . --keep 10 --yes
scripts/cc-watch prune --cwd . --keep 10
scripts/cc-watch prune --cwd . --keep 10 --yes
scripts/cc-watch repair-stale --cwd .
scripts/cc-watch repair-stale --cwd . --yes
scripts/cc-watch repair-stale --cwd . --json
```

`prune` never removes running jobs, and `prune --yes` requires an explicit
selector such as `--keep`, `--older-than-days`, or `--all-terminal`.
`repair-stale` is the dry-run-first cleanup step for old non-terminal jobs
whose worker, Claude, and watchdog processes have all died. It writes a failed
result archive with `--yes`; it never deletes job directories or kills PIDs.
`selected` is counted before the final safety re-check, so `repaired` may be
lower if a job changes state during the command. Use `--json` for structured
cleanup reports. In JSON output, `records` is the pre-check snapshot and
`apply_records` contains only `--yes` outcomes for jobs that reached the final
safety re-check.

## MCP Reading

Claude can read from SiYuan or Zotero only when the local Claude Code
installation already has those MCP servers configured and the helper is given
explicit tools. Do not use prompt text as the permission boundary.

Prefer this shape:

```bash
scripts/cc-watch run --persist-session --cwd . --title paper-review \
  --mcp-tool mcp__siyuan__siyuan_ping \
  --mcp-tool mcp__zotero__zotero_ping \
  -- "Verify read-only MCP visibility, then report what tools are available."
```

Then resume the same title with the specific read-only search/get tools needed
for the task. Tool names are installation-dependent; use the exact Claude Code
MCP tool names. Start with ping/list/search/get style tools. Do not allow
write/delete/move tools unless the user explicitly approves the side effect.
Use broad `--allow-mcp` only for a deliberate diagnostic where the prompt and
environment are already safe.

## Strict Review Hooks

Use this stricter loop when the user asks for rigorous work, when a task is
large or risky, or when working in a long-running `/goals` style task where the
user may be away:

1. Pick a stable title for the task, such as `goal-cc-watch-heartbeat`. If a
   matching persisted job already exists, resume it by title instead of
   starting a fresh Claude context.
2. Before editing, ask Claude for a read-only plan review. Include the intended
   changes, constraints, risks, and tests. Codex should inspect Claude's
   findings before making edits.
3. After editing and running local checks, resume the same Claude thread for a
   read-only diff review. Include `git diff --stat`, relevant test output, and
   the key diff or file list. Codex should address concrete findings or explain
   why they are deferred before finalizing.
4. Keep Claude read-only by default. Do not pass `--read-write`, broad
   `--allow-mcp`, or `--allow-bash` unless the user explicitly approves the
   added capability. For MCP, prefer explicit `--mcp-tool` entries.

Suggested titles:

```bash
scripts/cc-watch run --persist-session --cwd . --title strict-review -- "Review this implementation plan..."
scripts/cc-watch resume --cwd . strict-review -- "Review this completed diff..."
```

## Prompt Shape

Use plain Markdown:

```text
Task:
Review the current branch as a read-only second reviewer.

Context:
- cwd: /absolute/path
- branch: feature-x
- base: main
- constraints: do not edit files; do not print secrets

What to inspect:
- Current git diff
- Relevant tests or docs

Output:
- Findings first, ordered by severity
- File/line references where possible
- Mention uncertainty and verification gaps
```

For research tasks, ask Claude to produce sources, claims, uncertainty, and a
short synthesis that Codex can merge with its own findings.
