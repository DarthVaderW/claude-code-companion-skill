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

`cc-watch` passes `--no-session-persistence` to Claude Code by default. Use
`--persist-session` only when you explicitly want Claude Code to save a
print-mode session for later resume.

## Install As A Codex Skill

This repository does not create `.agents/skills` for you.

To install repo-locally, copy or symlink `claude-code-companion/` into the target
repository's Codex skills directory:

```text
<target-repo>/.agents/skills/claude-code-companion/
```

To install for personal use across repositories, copy it into your user Codex
skills directory. Do that manually only when you are comfortable with that
user-level write.

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
