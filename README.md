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

For the common "review my current branch/diff" case, let `cc-watch` build the
prompt from tracked git changes and keep Claude in the default read-only mode:

```bash
claude-code-companion/scripts/cc-watch review-diff --cwd . --base origin/main --title release-review
```

`review-diff` embeds committed, staged, and unstaged tracked diffs in
`prompt.md`; that raw diff is also sent to Claude. It intentionally does not
embed untracked file contents. Use `--max-diff-bytes N` to cap the diff included
in the prompt.

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
disable the timeout. For foreground `run`/`resume`, add `--heartbeat SEC` to
print compact progress lines while Claude is still working:

```bash
claude-code-companion/scripts/cc-watch run --cwd . --heartbeat 60 --max-runtime 900 -- "Long Opus review."
```

`status` returns zero for running jobs by default. Existing polling loops should
pass `--strict-exit` when they need non-zero exits for `running-*`.
`result` prints `result.txt` for any terminal job and exits non-zero for
failed, timed-out, or canceled jobs. Pass `result --json` when Codex or another
script needs the metadata plus final answer as a single machine-readable object:

```bash
claude-code-companion/scripts/cc-watch result "$job_id" --cwd . --json
```

Use `list` and `show` to find and read archived jobs without copying job ids:

```bash
claude-code-companion/scripts/cc-watch list --cwd .
claude-code-companion/scripts/cc-watch list --cwd . --json
claude-code-companion/scripts/cc-watch show --cwd . --last
claude-code-companion/scripts/cc-watch findings --cwd . --last
claude-code-companion/scripts/cc-watch show --cwd . repo-review --transcript
```

Use `list --json` when Codex or another script needs a newest-first structured
job list with status, session, timing, and archive paths.
Use `findings` when Codex needs the review sections from a finished job without
re-reading the full transcript; it preserves the matched Markdown sections and
also supports `--json`.

Clean up old local job archives with dry-run-first commands:

```bash
claude-code-companion/scripts/cc-watch archive --cwd . --keep 10
claude-code-companion/scripts/cc-watch archive --cwd . --keep 10 --yes
claude-code-companion/scripts/cc-watch prune --cwd . --keep 10
claude-code-companion/scripts/cc-watch prune --cwd . --keep 10 --yes
claude-code-companion/scripts/cc-watch repair-stale --cwd .
claude-code-companion/scripts/cc-watch repair-stale --cwd . --yes
```

`archive` writes a tarball under `.cc-watch/archives/`. `prune` never removes
running jobs, and `prune --yes` requires an explicit selector such as `--keep`,
`--older-than-days`, or `--all-terminal`. `archive --yes` without a selector
archives every terminal job. `--keep` and `--older-than-days` require positive
integers; use `--all-terminal` when you intentionally want all terminal jobs.
`repair-stale` is also dry-run by default. It does not delete directories or
kill processes; with `--yes`, it marks old non-terminal jobs as `failed` only
when no worker, Claude, or watchdog process is alive. Recent no-PID `starting`
jobs are skipped for 30 seconds by default; adjust with `--grace-seconds N`.
In `--yes` output, `selected=N` is the pre-repair candidate count; `repaired=N`
can be lower if the command re-checks a job and finds that it became terminal
or live again before mutation.

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
claude-code-companion/scripts/cc-watch run --mcp-tool mcp__siyuan__siyuan_ping --cwd . -- "Use one configured MCP tool."
claude-code-companion/scripts/cc-watch run --read-write --cwd . -- "Take over edits."
```

Do not use `--read-write` for ordinary Codex/Claude collaboration. Prefer
having Codex pass the relevant diff or file excerpts in the prompt.
Use broad `--allow-mcp` only for deliberate diagnostics. For ordinary
SiYuan/Zotero reads, pass one or more exact read-only MCP tool names with
`--mcp-tool TOOL`; this loads Claude Code's MCP config but keeps `--tools`
narrow. Tool names are installation-dependent, for example
`mcp__siyuan__siyuan_ping` or `mcp__zotero__zotero_ping`.

For rigorous projects or long-running `/goals` style work, use a strict review
loop: ask Claude for a read-only plan review before editing, then ask Claude for
a read-only diff review after edits and local checks. Codex remains responsible
for deciding which findings to implement.
Use one stable persisted title for the whole task and resume it for later
reviews so Claude keeps context:

```bash
claude-code-companion/scripts/cc-watch run --persist-session --cwd . --title goal-review --heartbeat 60 -- "Start the long-task review."
claude-code-companion/scripts/cc-watch resume --cwd . goal-review --heartbeat 60 -- "Continue with the latest diff."
```

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

For MCP-backed research, start with a persisted thread and explicit read-only
tools:

```bash
claude-code-companion/scripts/cc-watch run --persist-session --cwd . --title paper-review \
  --mcp-tool mcp__siyuan__siyuan_ping \
  --mcp-tool mcp__zotero__zotero_ping \
  -- "Verify MCP visibility and summarize the available read-only path."
```

Then resume the same title with the specific SiYuan/Zotero read tools needed for
the paper or project task. Do not allow MCP write/delete/move tools unless the
user explicitly approves that side effect.

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
  --ref v0.5.4
```

Restart Codex after installing or updating skills.

### Updating

For a local development symlink, update this checkout with `git pull`. The
symlink points at the working tree, so script changes are available immediately;
restart Codex when `SKILL.md` changes.

For stable installs, rerun the skill installer with the newest published
`--ref` tag. The example above tracks the latest release tag. Restart Codex
after the installer replaces the skill.

Release this repo by moving the changelog entries under a new version heading,
updating the installer `--ref` example, committing, creating an annotated tag,
and pushing both the branch and tag.

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
