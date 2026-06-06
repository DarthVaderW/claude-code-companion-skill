# Claude Code Companion Skill

Minimal Codex skill package for asking Claude Code for a second opinion without
flooding Codex context with raw `stream-json` output.

This project intentionally contains only:

```text
claude-code-companion/
  SKILL.md
  scripts/
    cc-watch
    cc-plugin
```

It is not a Codex plugin, MCP server, Python package, or uvx tool. It does not
install anything and does not write to `~/.codex`, `~/.claude`, `~/.local`, or
global Python/Node locations.

## Use

Run directly from this checkout:

```bash
claude-code-companion/scripts/cc-watch run --cwd . --title release-review -- "Review the current changes."
```

For long prompts, store the prompt in a Markdown file and pass it explicitly:

```bash
claude-code-companion/scripts/cc-watch run --cwd . --prompt-file review.md
```

Relative prompt-file paths are resolved from the shell invocation directory, not
from `--cwd`.

Check local readiness without sending a model request:

```bash
claude-code-companion/scripts/cc-watch doctor --cwd .
```

For longer tasks:

```bash
job_id="$(claude-code-companion/scripts/cc-watch start --cwd . --title repo-review -- "Investigate this repo.")"
claude-code-companion/scripts/cc-watch status "$job_id"
claude-code-companion/scripts/cc-watch result "$job_id"
```

When Codex itself is calling Claude, prefer foreground `run`; it waits without
printing raw stream-json. Some Codex command runners clean background children
when a tool call exits, so `start/status/result` is best for a normal terminal,
a persistent shell, or a single shell script that starts and waits in one go.
`status` includes `elapsed=<seconds>`, and jobs time out after 1800 seconds by
default. Override that with `--max-runtime SEC`, or use `--max-runtime 0` to
disable the timeout.
`status` returns zero for running jobs by default. Existing polling loops should
pass `--strict-exit` when they need non-zero exits for `running-*`.
`result` prints `result.txt` for any terminal job and exits non-zero for
failed, timed-out, or canceled jobs.
Use `list` and `show` to find and read archived jobs without copying job ids:

```bash
claude-code-companion/scripts/cc-watch list --cwd .
claude-code-companion/scripts/cc-watch show --cwd . --last
claude-code-companion/scripts/cc-watch show --cwd . repo-review --transcript
```

Runtime state for async jobs is written under the target working directory by
default:

```text
.cc-watch/
```

Each job directory keeps both human-readable and raw evidence:

```text
.cc-watch/<job-id>/
  prompt.md          Prompt sent to Claude
  result.txt         Human-readable result archive for every terminal state
  transcript.md      Prompt plus Claude result for future reading
  metadata.json      Machine-readable job metadata
  metadata.md        Human-readable job metadata
  stdout.jsonl       Raw Claude stream-json
  stderr.log         Raw stderr and failure details
```

`result.txt` is guaranteed for terminal jobs. On success it contains Claude's
final answer. On `failed`, `timed-out`, or `canceled`, it contains a status
header plus `NO FINAL RESULT`, the reason, denied/disallowed tool warnings when
detected, the last assistant text seen before failure when available, stderr
tail, and raw stream tail when available. Treat `stdout.jsonl` as the lossless
source of truth and
`result.txt` as the convenient human entry point. Use `transcript.md` when a
future Codex thread or CLI user needs to read the prompt and answer together.

You can remove that directory at any time after jobs finish.

The state directory writes its own `.gitignore` and this repo ignores
`.cc-watch/`, so prompts and raw stream logs should not be committed by
accident.

To keep archives outside the target project, pass a state root explicitly:

```bash
claude-code-companion/scripts/cc-watch run --cwd . --state-root /path/to/reviews --allow-external-state-root -- "Review this repo."
```

Custom state roots are nested under `DIR/.cc-watch/` so the helper does not
write a catch-all `.gitignore` into a user-owned parent directory. Commands
that read existing jobs, such as `status`, `result`, `list`, `show`, and
`resume`, need the same `--state-root` value. If that state root is outside
`--cwd`, those read commands must also repeat `--allow-external-state-root`.

## Security Model

`cc-watch` treats Claude Code as a read-only reviewer by default:

- Allowed built-in tools: `Read`, `Grep`, `Glob`, `LS` when supported by Claude.
- MCP config is disabled by default with a strict empty MCP config.
- Session persistence is disabled by default with `--no-session-persistence`.
- Raw `stream-json` is saved locally; `result.txt` is the human-readable
  archive view.
- Human-readable outputs are best-effort redacted for secret-shaped strings
  such as bearer tokens, `sk-*` keys, token query parameters, and common
  Claude/proxy environment values. `stdout.jsonl` remains the local lossless
  evidence file.

Use explicit opt-ins only when needed:

```bash
claude-code-companion/scripts/cc-watch run --allow-bash --cwd . -- "Inspect git diff read-only."
claude-code-companion/scripts/cc-watch run --allow-mcp --cwd . -- "Use configured MCP read-only."
claude-code-companion/scripts/cc-watch run --read-write --cwd . -- "Take over edits."
```

Do not use `--read-write` for ordinary Codex/Claude collaboration. Prefer
having Codex pass the relevant diff or file excerpts in the prompt.

`cc-watch` passes `--no-session-persistence` to Claude Code by default. Use
`--persist-session` only when you explicitly want Claude Code to save a
print-mode session for later resume. Default jobs still record a `session_id`
when Claude emits one, but they are not resumable.

Resume modes are explicit:

```bash
claude-code-companion/scripts/cc-watch run --persist-session --cwd . --title repo-review -- "Start a reusable Claude thread."
claude-code-companion/scripts/cc-watch resume --cwd . repo-review -- "Continue that thread."
claude-code-companion/scripts/cc-watch resume --cwd . <job-id> -- "Continue by job id."
claude-code-companion/scripts/cc-watch resume --cwd . <session-id> -- "Continue by raw Claude session id."
claude-code-companion/scripts/cc-watch run --continue --cwd . -- "Continue Claude's latest cwd thread."
```

`resume` resolves selectors in this order: exact job id, exact title with the
most recent matching job, then raw session id. When resuming from a job or title
it refuses jobs that were not started with `--persist-session`.

## Install As A Codex Skill

This repository does not create `.agents/skills` for you.

For local development, symlink `claude-code-companion/` into your personal Codex
skills directory:

```bash
mkdir -p "${CODEX_HOME:-$HOME/.codex}/skills"
ln -s /path/to/codex-cc-plugin/claude-code-companion \
  "${CODEX_HOME:-$HOME/.codex}/skills/claude-code-companion"
```

For stable multi-Mac installs, use Codex's skill installer from the GitHub repo:

```bash
python3 ~/.codex/skills/.system/skill-installer/scripts/install-skill-from-github.py \
  --repo DarthVaderW/claude-code-companion-skill \
  --path claude-code-companion \
  --ref v0.4.0
```

Restart Codex after installing or updating skills.

This project is not a `uvx` tool. Do not add `pyproject.toml` or a Python
package only to install this skill.

## Claude Plugin Read-Only Checks

`cc-plugin` is a sibling helper for inspecting Claude Code plugin state without
mutating global plugin installs:

```bash
claude-code-companion/scripts/cc-plugin doctor --cwd .
claude-code-companion/scripts/cc-plugin list --cwd .
claude-code-companion/scripts/cc-plugin versions --cwd .
claude-code-companion/scripts/cc-plugin plan-update --cwd . --plugin siyuan-mcp --plugin zotero-mcp
```

`plan-update` is a dry run. It prints the commands a human could run later, but
it does not execute `claude plugin marketplace update` or `claude plugin
update`. Any future helper that mutates `~/.claude` must be explicit, opt-in,
and documented separately from the read-only reviewer path.

On Claude CLI builds that do not provide `claude plugin versions`, `versions`
falls back to `claude plugin list` and reports that latest-version detection is
unavailable without a supported CLI command.

## Requirements

- Claude Code CLI available as `claude`, or set `CLAUDE_BIN=/path/to/claude`.
- Bash.
- Perl with `JSON::PP`, which is used only to decode the final Claude result
  event. No Perl packages are installed by this project.

## Status Model

`cc-watch` distinguishes process life from stream activity:

```text
running-active  Claude child process is alive and stream-json emitted recently.
running-quiet   Claude child process is alive but has been quiet for a while.
finished        Final result was received and the process exited successfully.
failed          Process exited non-zero or exited without a final result.
canceled        User canceled the job.
timed-out       Job exceeded --max-runtime.
unknown         Job state is missing or cannot be verified.
```

Quiet does not mean failed. Claude may be doing web search, local search, file
reads, or a long tool call without producing stream events.
