# Claude Code Companion Skill

Minimal Codex skill package for asking Claude Code for a second opinion without
flooding Codex context with raw `stream-json` output.

This project intentionally contains only:

```text
claude-code-companion/
  SKILL.md
  scripts/
    cc-watch
```

It is not a Codex plugin, MCP server, Python package, or uvx tool. It does not
install anything and does not write to `~/.codex`, `~/.claude`, `~/.local`, or
global Python/Node locations.

## Use

Run directly from this checkout:

```bash
claude-code-companion/scripts/cc-watch run --cwd . -- "Review the current changes."
```

Check local readiness without sending a model request:

```bash
claude-code-companion/scripts/cc-watch doctor --cwd .
```

For longer tasks:

```bash
job_id="$(claude-code-companion/scripts/cc-watch start --cwd . -- "Investigate this repo.")"
claude-code-companion/scripts/cc-watch status "$job_id"
claude-code-companion/scripts/cc-watch result "$job_id"
```

Runtime state for async jobs is written only under the target working directory:

```text
.cc-watch/
```

You can remove that directory at any time after jobs finish.

The state directory writes its own `.gitignore` and this repo ignores
`.cc-watch/`, so prompts and raw stream logs should not be committed by
accident.

## Security Model

`cc-watch` treats Claude Code as a read-only reviewer by default:

- Allowed built-in tools: `Read`, `Grep`, `Glob`, `LS` when supported by Claude.
- MCP config is disabled by default with a strict empty MCP config.
- Session persistence is disabled by default with `--no-session-persistence`.
- Raw `stream-json` is saved locally but only the final result is printed.

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
print-mode session for later resume.

Resume modes are explicit:

```bash
claude-code-companion/scripts/cc-watch run --persist-session --cwd . -- "Start a reusable Claude thread."
claude-code-companion/scripts/cc-watch run --resume <session-id> --cwd . -- "Continue that thread."
claude-code-companion/scripts/cc-watch run --continue --cwd . -- "Continue Claude's latest cwd thread."
```

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
  --ref v0.2.0
```

Restart Codex after installing or updating skills.

This project is not a `uvx` tool. Do not add `pyproject.toml` or a Python
package only to install this skill.

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
unknown         Job state is missing or cannot be verified.
```

Quiet does not mean failed. Claude may be doing web search, local search, file
reads, or a long tool call without producing stream events.
