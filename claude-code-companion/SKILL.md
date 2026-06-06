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
- Prefer passing diffs, file lists, or command output in the prompt. Use
  `--allow-bash` only when Claude genuinely needs shell access.
- For long prompts, write a Markdown prompt file and pass `--prompt-file`.
- Use `--read-write` only when the user explicitly asks Claude Code to take over
  edits. Codex should normally remain the writer.
- Use the helper's default fresh non-persistent print-mode session for one-off
  reviews. Pass `--persist-session` when a new Claude session should be
  resumable, `--resume <session-id>` to continue a known session, or
  `--continue` only when continuing Claude's latest cwd session is intended.
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
scripts/cc-watch run --cwd . -- "Review the current diff. Return only actionable findings."
```

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
scripts/cc-watch run --persist-session --cwd . -- "Start a reusable review thread."
scripts/cc-watch run --resume <session-id> --cwd . -- "Continue that review."
```

For long work from a persistent terminal or one shell script:

```bash
job_id="$(scripts/cc-watch start --cwd . -- "Investigate this repo and report risks.")"
scripts/cc-watch status "$job_id"
scripts/cc-watch result "$job_id"
```

When running inside Codex tool calls, prefer foreground `run` unless the shell
will remain alive; some command runners clean background children when the tool
call exits. Use `status` while waiting. `running-quiet` means Claude is still
alive but has not emitted stream-json recently; do not treat it as failure. Use
`--max-runtime SEC` to bound long Opus jobs when needed.

Every terminal job writes `.cc-watch/<job-id>/result.txt`, `metadata.json`,
`metadata.md`, `prompt.md`, `stdout.jsonl`, and `stderr.log`. Treat
`result.txt` as the human-readable archive entry and `stdout.jsonl` as the
lossless raw evidence. `result` prints `result.txt` for any terminal job and
exits non-zero for failed, timed-out, or canceled jobs. `status` returns zero
for running jobs by default; use `--strict-exit` only when a script needs
polling-style non-zero exits.

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
