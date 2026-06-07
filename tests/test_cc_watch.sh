#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC_WATCH="$ROOT/claude-code-companion/scripts/cc-watch"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_CLAUDE="$TMP_ROOT/fake-claude"
cat > "$FAKE_CLAUDE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_ARGS_LOG"

if [ "${1:-}" = "--version" ]; then
  printf 'fake claude 0.0.0\n'
  exit 0
fi
if [ "${1:-}" = "--help" ]; then
  cat <<'HELP'
Usage: fake claude
  -p, --print
  --output-format stream-json
  --tools
  --strict-mcp-config
  --no-session-persistence
  --permission-mode
HELP
  exit 0
fi
if [ -n "${FAKE_PID_FILE:-}" ]; then
  printf '%s\n' "$$" > "$FAKE_PID_FILE"
fi

case "${FAKE_BEHAVIOR:-success}" in
  success)
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"11111111-1111-1111-1111-111111111111"}'
    printf '%s\n' '{"type":"result","subtype":"success","session_id":"11111111-1111-1111-1111-111111111111","result":"fake final review"}'
    ;;
  no-result)
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"11111111-1111-1111-1111-111111111111"}'
    ;;
  error-result)
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"11111111-1111-1111-1111-111111111111"}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":true,"session_id":"11111111-1111-1111-1111-111111111111","result":"fake auth error"}'
    ;;
  partial-result)
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"11111111-1111-1111-1111-111111111111"}'
    printf '%s' '{"type":"result","subtype":"success","session_id":"11111111-1111-1111-1111-111111111111","result":"fake final review"}'
    ;;
  findings)
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"11111111-1111-1111-1111-111111111111"}'
    printf '%s\n' '{"type":"result","subtype":"success","session_id":"11111111-1111-1111-1111-111111111111","result":"Intro paragraph.\n\n## Findings\n\n### P1: Bug\nActionable finding body.\n\n```md\n## Not a real heading\n```\n\n### P2: Risk\nRisk body with sk-ant-secretvalue.\n\n## Appendix\nThis should not be in findings output."}'
    ;;
  findings-summary)
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"11111111-1111-1111-1111-111111111111"}'
    printf '%s\n' '{"type":"result","subtype":"success","session_id":"11111111-1111-1111-1111-111111111111","result":"## Summary\nShort verdict.\n\n## Analysis\nSubstantive analysis body.\n\n## Appendix\nIgnored appendix."}'
    ;;
  fail)
    printf 'fake failure\n' >&2
    exit 42
    ;;
  partial-fail)
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"11111111-1111-1111-1111-111111111111"}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Partial useful review before the socket failed. Keep this paragraph visible."}]}}'
    printf '%s\n' '{"type":"system","message":"permission denied: tool Write is not allowed by cc-watch"}'
    printf 'Permission denied for tool Write before final result.\n' >&2
    exit 42
    ;;
  secret-success)
    printf 'stderr Authorization: Bearer STDERRSECRET Proxy-Authorization: Basic PROXYSECRET sk-ant-stderrsecret ANTHROPIC_API_KEY=stderr-secret http_proxy=http://user:pass@proxy\n' >&2
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"11111111-1111-1111-1111-111111111111"}'
    printf '%s\n' '{"type":"result","subtype":"success","session_id":"11111111-1111-1111-1111-111111111111","result":"Authorization: Bearer SECRET123 Authorization: Basic BASICSECRET x-api-key: HEADERSECRET sk-ant-secretvalue https://example.test/?token=tokensecret ANTHROPIC_API_KEY=envsecret"}'
    ;;
  secret-fail)
    printf 'fake failure Authorization: Bearer FAILSECRET Proxy-Authorization: Basic FAILBASIC x-api-key: FAILHEADER sk-ant-failsecret https://example.test/?api_key=failkey HTTP_PROXY=http://proxy-secret https_proxy=http://lower-proxy-secret\n' >&2
    exit 42
    ;;
  slow)
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"11111111-1111-1111-1111-111111111111"}'
    sleep 30
    printf '%s\n' '{"type":"result","subtype":"success","session_id":"11111111-1111-1111-1111-111111111111","result":"fake final review"}'
    ;;
  *)
    printf 'unknown fake behavior: %s\n' "$FAKE_BEHAVIOR" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$FAKE_CLAUDE"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "expected [$haystack] to contain [$needle]" ;;
  esac
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  case "$haystack" in
    *"$needle"*) fail "expected [$haystack] not to contain [$needle]" ;;
    *) ;;
  esac
}

assert_json_file() {
  local path="$1"
  perl -MJSON::PP -e 'local $/; JSON::PP->new->decode(<STDIN>);' < "$path" \
    || fail "invalid JSON file: $path"
}

wait_for_status() {
  local work="$1"
  local job="$2"
  local pattern="$3"
  local status_text=""
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    status_text="$("$CC_WATCH" status "$job" --cwd "$work" 2>/dev/null || true)"
    case "$status_text" in
      *"$pattern"*)
        printf '%s\n' "$status_text"
        return 0
        ;;
    esac
    sleep 0.2
  done
  fail "job $job did not reach status pattern [$pattern], last status [$status_text]"
}

wait_for_file() {
  local path="$1"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$path" ] && return 0
    sleep 0.2
  done
  fail "file was not written: $path"
}

job_id_for_work() {
  local work="$1"
  cat "$work/.cc-watch"/*/job_id
}

job_dir_for_work() {
  local work="$1"
  local job
  job="$(job_id_for_work "$work")"
  printf '%s/.cc-watch/%s\n' "$work" "$job"
}

count_job_dirs_for_work() {
  local work="$1"
  find "$work/.cc-watch" -maxdepth 2 -name job_id 2>/dev/null | wc -l | tr -d ' '
}

job_id_for_state_parent() {
  local parent="$1"
  cat "$parent/.cc-watch"/*/job_id
}

job_dir_for_state_parent() {
  local parent="$1"
  local job
  job="$(job_id_for_state_parent "$parent")"
  printf '%s/.cc-watch/%s\n' "$parent" "$job"
}

new_workdir() {
  local dir="$TMP_ROOT/work-$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

mark_job_stale() {
  local dir="$1"
  local status="$2"
  local worker_pid="${3:-}"
  local claude_pid="${4:-}"
  local watchdog_pid="${5:-}"
  local started_at="${6:-1}"
  printf '%s\n' "$status" > "$dir/status"
  printf '%s\n' "$worker_pid" > "$dir/worker_pid"
  printf '%s\n' "$claude_pid" > "$dir/claude_pid"
  printf '%s\n' "$watchdog_pid" > "$dir/watchdog_pid"
  printf '%s\n' "$started_at" > "$dir/started_at"
  : > "$dir/final-text.txt"
  : > "$dir/stdout.jsonl"
  : > "$dir/stderr.log"
  rm -f "$dir/final-result.json" "$dir/result.txt" "$dir/transcript.md" "$dir/metadata.json" "$dir/metadata.md"
}

new_git_workdir() {
  local dir
  dir="$(new_workdir "$1")"
  git -C "$dir" init -q
  git -C "$dir" config user.email cc-watch-test@example.invalid
  git -C "$dir" config user.name "cc-watch test"
  printf 'base\n' > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit -qm "base"
  printf '%s\n' "$dir"
}

run_success_with_behavior() {
  local label="$1"
  local behavior="$2"
  shift 2
  local work args_log output
  work="$(new_workdir "$label")"
  args_log="$TMP_ROOT/$label.args"
  output="$TMP_ROOT/$label.out"
  FAKE_ARGS_LOG="$args_log" FAKE_BEHAVIOR="$behavior" \
    "$CC_WATCH" run --cwd "$work" --claude "$FAKE_CLAUDE" "$@" -- "review only" > "$output"
  assert_contains "$(cat "$output")" "fake final review"
  assert_contains "$(cat "$(job_dir_for_work "$work")/result.txt")" "# cc-watch result"
  assert_contains "$(cat "$(job_dir_for_work "$work")/transcript.md")" "# cc-watch transcript"
  assert_contains "$(cat "$(job_dir_for_work "$work")/metadata.json")" '"status": "finished"'
  assert_contains "$(cat "$(job_dir_for_work "$work")/metadata.json")" '"state_root":'
  assert_contains "$(cat "$(job_dir_for_work "$work")/metadata.json")" '"external_state": "0"'
  assert_json_file "$(job_dir_for_work "$work")/metadata.json"
  assert_contains "$(cat "$(job_dir_for_work "$work")/metadata.md")" "# cc-watch metadata"
  [ -f "$work/.cc-watch/.gitignore" ] || fail "missing state .gitignore"
  tail -1 "$args_log"
}

run_success() {
  local label="$1"
  shift
  run_success_with_behavior "$label" success "$@"
}

default_args="$(run_success default)"
assert_contains "$default_args" "--no-session-persistence"
assert_contains "$default_args" "--tools Read,Grep,Glob,LS"
assert_contains "$default_args" "--strict-mcp-config --mcp-config {\"mcpServers\":{}}"
assert_not_contains "$default_args" "--disallowed-tools"
assert_not_contains "$default_args" "Bash"
default_job="$(job_id_for_work "$TMP_ROOT/work-default")"
"$CC_WATCH" result "$default_job" --cwd "$TMP_ROOT/work-default" --json > "$TMP_ROOT/default-result.json"
assert_json_file "$TMP_ROOT/default-result.json"
assert_contains "$(cat "$TMP_ROOT/default-result.json")" '"result_text"'
assert_contains "$(cat "$TMP_ROOT/default-result.json")" "fake final review"

version_text="$("$CC_WATCH" --version)"
assert_contains "$version_text" "cc-watch 0.5.6"

allow_bash_args="$(run_success allow-bash --allow-bash)"
assert_contains "$allow_bash_args" "--tools Read,Grep,Glob,LS,Bash"
assert_contains "$allow_bash_args" "--strict-mcp-config"

allow_mcp_args="$(run_success allow-mcp --allow-mcp)"
assert_contains "$allow_mcp_args" "--tools Read,Grep,Glob,LS"
assert_not_contains "$allow_mcp_args" "--strict-mcp-config"

mcp_tool_args="$(run_success mcp-tool --mcp-tool mcp__siyuan__siyuan_ping --mcp-tool mcp__zotero__zotero_ping)"
assert_contains "$mcp_tool_args" "--tools Read,Grep,Glob,LS,mcp__siyuan__siyuan_ping,mcp__zotero__zotero_ping"
assert_not_contains "$mcp_tool_args" "--strict-mcp-config"
mcp_tool_dir="$(job_dir_for_work "$TMP_ROOT/work-mcp-tool")"
assert_contains "$(cat "$mcp_tool_dir/metadata.json")" '"mcp_tools": ["mcp__siyuan__siyuan_ping","mcp__zotero__zotero_ping"]'
assert_contains "$(cat "$mcp_tool_dir/metadata.md")" "- mcp_tools: \`mcp__siyuan__siyuan_ping,mcp__zotero__zotero_ping\`"

if FAKE_ARGS_LOG="$TMP_ROOT/bad-mcp-tool.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$(new_workdir bad-mcp-tool)" --claude "$FAKE_CLAUDE" \
  --mcp-tool "bad,tool" -- "review only" >/dev/null 2>&1; then
  fail "mcp tool with comma should fail"
fi

if FAKE_ARGS_LOG="$TMP_ROOT/mcp-tool-read-write.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$(new_workdir mcp-tool-read-write)" --claude "$FAKE_CLAUDE" \
  --mcp-tool mcp__siyuan__siyuan_ping --read-write -- "review only" >/dev/null 2>&1; then
  fail "--mcp-tool with --read-write should fail"
fi

read_write_args="$(run_success read-write --read-write)"
assert_not_contains "$read_write_args" "--tools"
assert_contains "$read_write_args" "--strict-mcp-config"

resume_args="$(run_success resume --resume 11111111-1111-1111-1111-111111111111)"
assert_contains "$resume_args" "--resume 11111111-1111-1111-1111-111111111111"
assert_not_contains "$resume_args" "--no-session-persistence"

continue_args="$(run_success continue --continue)"
assert_contains "$continue_args" "--continue"
assert_not_contains "$continue_args" "--no-session-persistence"

title_args="$(run_success title --title "release review")"
title_dir="$(job_dir_for_work "$TMP_ROOT/work-title")"
assert_contains "$(cat "$title_dir/result.txt")" "- title: \`release review\`"
assert_contains "$(cat "$title_dir/metadata.json")" '"title": "release review"'
assert_contains "$(cat "$title_dir/transcript.md")" "## Prompt"
assert_not_contains "$title_args" "--name"

if FAKE_ARGS_LOG="$TMP_ROOT/bad-title.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$(new_workdir bad-title)" --claude "$FAKE_CLAUDE" \
  --title "bad/title" -- "review only" >/dev/null 2>&1; then
  fail "title with slash should fail"
fi

review_work="$(new_git_workdir review-diff)"
printf 'base\nchange\n' > "$review_work/file.txt"
review_args="$TMP_ROOT/review-diff.args"
FAKE_ARGS_LOG="$review_args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" review-diff --cwd "$review_work" --claude "$FAKE_CLAUDE" --base HEAD \
  --max-diff-bytes 100000 > "$TMP_ROOT/review-diff.out"
review_dir="$(job_dir_for_work "$review_work")"
review_args_text="$(tail -1 "$review_args")"
assert_contains "$(cat "$TMP_ROOT/review-diff.out")" "fake final review"
assert_contains "$review_args_text" "--tools Read,Grep,Glob,LS"
assert_contains "$review_args_text" "--strict-mcp-config"
assert_not_contains "$review_args_text" "Bash"
assert_contains "$(cat "$review_dir/prompt.md")" "base_ref: HEAD"
assert_contains "$(cat "$review_dir/prompt.md")" "+change"
assert_contains "$(cat "$review_dir/metadata.json")" '"review_kind": "diff"'
assert_contains "$(cat "$review_dir/metadata.json")" '"review_base": "HEAD"'
assert_contains "$(cat "$review_dir/metadata.json")" '"review_diff_truncated": "0"'

review_trunc_work="$(new_git_workdir review-diff-truncated)"
printf 'base\nvery long change line\n' > "$review_trunc_work/file.txt"
FAKE_ARGS_LOG="$TMP_ROOT/review-diff-truncated.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" review-diff --cwd "$review_trunc_work" --claude "$FAKE_CLAUDE" --base HEAD \
  --max-diff-bytes 10 > "$TMP_ROOT/review-diff-truncated.out"
review_trunc_dir="$(job_dir_for_work "$review_trunc_work")"
assert_contains "$(cat "$review_trunc_dir/prompt.md")" "tracked diff truncated at 10 bytes"
assert_contains "$(cat "$review_trunc_dir/metadata.json")" '"review_diff_truncated": "1"'

review_default_work="$(new_git_workdir review-diff-default)"
printf 'base\ndefault base change\n' > "$review_default_work/file.txt"
printf 'untracked secret should stay out\n' > "$review_default_work/secret.txt"
(
  cd "$review_default_work"
  CLAUDE_BIN="$FAKE_CLAUDE" FAKE_ARGS_LOG="$TMP_ROOT/review-diff-default.args" FAKE_BEHAVIOR=success \
    "$CC_WATCH" review-diff > "$TMP_ROOT/review-diff-default.out"
)
review_default_dir="$(job_dir_for_work "$review_default_work")"
assert_contains "$(cat "$TMP_ROOT/review-diff-default.out")" "fake final review"
assert_contains "$(cat "$review_default_dir/prompt.md")" "default base change"
assert_contains "$(cat "$review_default_dir/prompt.md")" "?? secret.txt"
assert_not_contains "$(cat "$review_default_dir/prompt.md")" "untracked secret should stay out"
assert_contains "$(cat "$review_default_dir/metadata.json")" '"review_kind": "diff"'
assert_contains "$(cat "$review_default_dir/metadata.json")" '"review_base":'

review_clean_work="$(new_git_workdir review-diff-clean)"
if FAKE_ARGS_LOG="$TMP_ROOT/review-diff-clean.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" review-diff --cwd "$review_clean_work" --claude "$FAKE_CLAUDE" --base HEAD >/dev/null 2>&1; then
  fail "review-diff clean tree should fail"
fi
[ ! -d "$review_clean_work/.cc-watch" ] || fail "review-diff clean tree should not create a job"

if FAKE_ARGS_LOG="$TMP_ROOT/review-diff-bad-base.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" review-diff --cwd "$review_work" --claude "$FAKE_CLAUDE" --base --bad >/dev/null 2>&1; then
  fail "review-diff bad base should fail"
fi
[ ! -f "$TMP_ROOT/review-diff-bad-base.args" ] || fail "review-diff bad base spawned Claude"
if FAKE_ARGS_LOG="$TMP_ROOT/review-diff-allow-bash.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" review-diff --cwd "$review_work" --claude "$FAKE_CLAUDE" --base HEAD --allow-bash >/dev/null 2>&1; then
  fail "review-diff --allow-bash should fail"
fi
[ ! -f "$TMP_ROOT/review-diff-allow-bash.args" ] || fail "review-diff --allow-bash spawned Claude"

bad_work="$(new_workdir mutual-exclusion)"
bad_args_log="$TMP_ROOT/mutual-exclusion.args"
if FAKE_ARGS_LOG="$bad_args_log" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$bad_work" --claude "$FAKE_CLAUDE" \
  --resume 11111111-1111-1111-1111-111111111111 --continue -- "review only" >/dev/null 2>&1; then
  fail "--resume and --continue should be mutually exclusive"
fi

no_result_work="$(new_workdir no-result)"
no_result_args="$TMP_ROOT/no-result.args"
if FAKE_ARGS_LOG="$no_result_args" FAKE_BEHAVIOR=no-result \
  "$CC_WATCH" run --cwd "$no_result_work" --claude "$FAKE_CLAUDE" -- "review only" >/dev/null 2>&1; then
  fail "no-result run should fail"
fi
no_result_job="$(job_id_for_work "$no_result_work")"
set +e
"$CC_WATCH" result "$no_result_job" --cwd "$no_result_work" > "$TMP_ROOT/no-result-result.out" 2>&1
no_result_code="$?"
set -e
if [ "$no_result_code" -eq 0 ]; then
  fail "no-result result command should return non-zero"
fi
if [ "$no_result_code" -ne 1 ]; then
  fail "no-result result command should return 1, got $no_result_code"
fi
assert_contains "$(cat "$TMP_ROOT/no-result-result.out")" "NO FINAL RESULT"
assert_contains "$(cat "$TMP_ROOT/no-result-result.out")" "did not emit a final result"
set +e
"$CC_WATCH" result "$no_result_job" --cwd "$no_result_work" --json > "$TMP_ROOT/no-result-result.json" 2>&1
no_result_json_code="$?"
set -e
if [ "$no_result_json_code" -ne 1 ]; then
  fail "no-result result --json should return 1, got $no_result_json_code"
fi
assert_json_file "$TMP_ROOT/no-result-result.json"
assert_contains "$(cat "$TMP_ROOT/no-result-result.json")" '"status" : "failed"'
assert_contains "$(cat "$TMP_ROOT/no-result-result.json")" "NO FINAL RESULT"
assert_contains "$(cat "$(job_dir_for_work "$no_result_work")/metadata.json")" '"status": "failed"'
assert_json_file "$(job_dir_for_work "$no_result_work")/metadata.json"
no_result_status="$("$CC_WATCH" status "$no_result_job" --cwd "$no_result_work" || true)"
assert_contains "$no_result_status" "exit_code=1"
set +e
"$CC_WATCH" findings "$no_result_job" --cwd "$no_result_work" > "$TMP_ROOT/no-result-findings.out" 2>&1
no_result_findings_code="$?"
set -e
if [ "$no_result_findings_code" -ne 1 ]; then
  fail "no-result findings should return 1, got $no_result_findings_code"
fi
assert_contains "$(cat "$TMP_ROOT/no-result-findings.out")" "NO FINAL RESULT"
set +e
"$CC_WATCH" findings "$no_result_job" --cwd "$no_result_work" --json > "$TMP_ROOT/no-result-findings.json" 2>&1
no_result_findings_json_code="$?"
set -e
if [ "$no_result_findings_json_code" -ne 1 ]; then
  fail "no-result findings --json should return 1, got $no_result_findings_json_code"
fi
assert_json_file "$TMP_ROOT/no-result-findings.json"
assert_contains "$(cat "$TMP_ROOT/no-result-findings.json")" '"status" : "failed"'

error_result_work="$(new_workdir error-result)"
error_result_args="$TMP_ROOT/error-result.args"
if FAKE_ARGS_LOG="$error_result_args" FAKE_BEHAVIOR=error-result \
  "$CC_WATCH" run --cwd "$error_result_work" --claude "$FAKE_CLAUDE" -- "review only" >/dev/null 2>&1; then
  fail "error-result run should fail"
fi
error_result_job="$(job_id_for_work "$error_result_work")"
set +e
"$CC_WATCH" result "$error_result_job" --cwd "$error_result_work" > "$TMP_ROOT/error-result-result.out" 2>&1
error_result_code="$?"
set -e
if [ "$error_result_code" -eq 0 ]; then
  fail "error-result result command should return non-zero"
fi
if [ "$error_result_code" -ne 1 ]; then
  fail "error-result result command should return 1, got $error_result_code"
fi
assert_contains "$(cat "$TMP_ROOT/error-result-result.out")" "fake auth error"
assert_json_file "$(job_dir_for_work "$error_result_work")/metadata.json"

partial_result_args="$(run_success_with_behavior partial-result partial-result)"
assert_contains "$partial_result_args" "--tools Read,Grep,Glob,LS"

prompt_work="$(new_workdir prompt-file)"
prompt_args="$TMP_ROOT/prompt-file.args"
prompt_file="$TMP_ROOT/review-prompt.md"
prompt_output="$TMP_ROOT/prompt-file.out"
printf 'review from prompt file\n' > "$prompt_file"
FAKE_ARGS_LOG="$prompt_args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$prompt_work" --claude "$FAKE_CLAUDE" --prompt-file "$prompt_file" > "$prompt_output"
assert_contains "$(cat "$prompt_output")" "fake final review"
assert_contains "$(cat "$(job_dir_for_work "$prompt_work")/prompt.md")" "review from prompt file"
assert_contains "$(cat "$(job_dir_for_work "$prompt_work")/metadata.json")" "\"prompt_file\": \"$prompt_file\""

prompt_rel_work="$(new_workdir prompt-file-relative)"
prompt_rel_dir="$TMP_ROOT/prompt-file-relative-invocation"
mkdir -p "$prompt_rel_dir"
printf 'review from relative prompt file\n' > "$prompt_rel_dir/relative-review.md"
(
  cd "$prompt_rel_dir"
  FAKE_ARGS_LOG="$TMP_ROOT/prompt-file-relative.args" FAKE_BEHAVIOR=success \
    "$CC_WATCH" run --cwd "$prompt_rel_work" --claude "$FAKE_CLAUDE" \
      --prompt-file relative-review.md > "$TMP_ROOT/prompt-file-relative.out"
)
assert_contains "$(cat "$TMP_ROOT/prompt-file-relative.out")" "fake final review"
assert_contains "$(cat "$(job_dir_for_work "$prompt_rel_work")/prompt.md")" "review from relative prompt file"
assert_contains "$(cat "$(job_dir_for_work "$prompt_rel_work")/metadata.json")" '"prompt_file": "relative-review.md"'

if FAKE_ARGS_LOG="$TMP_ROOT/prompt-file-bad.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$prompt_work" --claude "$FAKE_CLAUDE" --prompt-file "$prompt_file" -- "extra prompt" >/dev/null 2>&1; then
  fail "--prompt-file should be mutually exclusive with prompt args"
fi
if FAKE_ARGS_LOG="$TMP_ROOT/prompt-file-missing.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$prompt_work" --claude "$FAKE_CLAUDE" --prompt-file "$TMP_ROOT/missing.md" >/dev/null 2>&1; then
  fail "missing --prompt-file should fail"
fi

stdin_work="$(new_workdir stdin-prompt)"
stdin_args="$TMP_ROOT/stdin-prompt.args"
printf 'review from stdin\n' | FAKE_ARGS_LOG="$stdin_args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$stdin_work" --claude "$FAKE_CLAUDE" > "$TMP_ROOT/stdin-prompt.out"
assert_contains "$(cat "$TMP_ROOT/stdin-prompt.out")" "fake final review"
assert_contains "$(cat "$(job_dir_for_work "$stdin_work")/prompt.md")" "review from stdin"

timeout_work="$(new_workdir timeout)"
timeout_args="$TMP_ROOT/timeout.args"
timeout_output="$TMP_ROOT/timeout.out"
if FAKE_ARGS_LOG="$timeout_args" FAKE_BEHAVIOR=slow \
  "$CC_WATCH" run --cwd "$timeout_work" --claude "$FAKE_CLAUDE" --max-runtime 1 -- "review only" > "$timeout_output" 2>&1; then
  fail "timeout run should fail"
fi
assert_contains "$(cat "$timeout_output")" "status=timed-out"
timeout_status="$("$CC_WATCH" status "$(cat "$timeout_work/.cc-watch"/*/job_id)" --cwd "$timeout_work" || true)"
assert_contains "$timeout_status" "timed-out"
assert_contains "$timeout_status" "elapsed="
timeout_job="$(job_id_for_work "$timeout_work")"
set +e
"$CC_WATCH" result "$timeout_job" --cwd "$timeout_work" > "$TMP_ROOT/timeout-result.out" 2>&1
timeout_result_code="$?"
set -e
if [ "$timeout_result_code" -eq 0 ]; then
  fail "timeout result command should return non-zero"
fi
if [ "$timeout_result_code" -ne 124 ]; then
  fail "timeout result command should return 124, got $timeout_result_code"
fi
assert_contains "$(cat "$TMP_ROOT/timeout-result.out")" "NO FINAL RESULT"
assert_contains "$(cat "$TMP_ROOT/timeout-result.out")" "max runtime"
assert_json_file "$(job_dir_for_work "$timeout_work")/metadata.json"

heartbeat_work="$(new_workdir heartbeat)"
heartbeat_args="$TMP_ROOT/heartbeat.args"
heartbeat_output="$TMP_ROOT/heartbeat.out"
set +e
FAKE_ARGS_LOG="$heartbeat_args" FAKE_BEHAVIOR=slow \
  "$CC_WATCH" run --cwd "$heartbeat_work" --claude "$FAKE_CLAUDE" \
  --max-runtime 2 --heartbeat 1 -- "review only" > "$heartbeat_output" 2>&1
heartbeat_code="$?"
set -e
if [ "$heartbeat_code" -eq 0 ]; then
  fail "heartbeat slow run should time out"
fi
assert_contains "$(cat "$heartbeat_output")" "[cc] heartbeat job="
assert_contains "$(cat "$heartbeat_output")" "elapsed="
assert_contains "$(cat "$heartbeat_output")" "status=timed-out"
assert_contains "$(cat "$(job_dir_for_work "$heartbeat_work")/metadata.json")" '"heartbeat": "1"'

if FAKE_ARGS_LOG="$TMP_ROOT/start-heartbeat.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" start --cwd "$(new_workdir start-heartbeat)" --claude "$FAKE_CLAUDE" \
  --heartbeat 1 -- "review only" >/dev/null 2>&1; then
  fail "start --heartbeat should fail because heartbeat is foreground-only"
fi

fail_work="$(new_workdir fail)"
fail_args="$TMP_ROOT/fail.args"
set +e
FAKE_ARGS_LOG="$fail_args" FAKE_BEHAVIOR=fail \
  "$CC_WATCH" run --cwd "$fail_work" --claude "$FAKE_CLAUDE" -- "review only" > "$TMP_ROOT/fail-run.out" 2>&1
fail_run_code="$?"
set -e
if [ "$fail_run_code" -eq 0 ]; then
  fail "non-zero Claude run should fail"
fi
if [ "$fail_run_code" -ne 42 ]; then
  fail "non-zero Claude run should return 42, got $fail_run_code"
fi
fail_job="$(job_id_for_work "$fail_work")"
set +e
"$CC_WATCH" result "$fail_job" --cwd "$fail_work" > "$TMP_ROOT/fail-result.out" 2>&1
fail_result_code="$?"
set -e
if [ "$fail_result_code" -eq 0 ]; then
  fail "fail result command should return non-zero"
fi
if [ "$fail_result_code" -ne 42 ]; then
  fail "fail result command should return 42, got $fail_result_code"
fi
assert_contains "$(cat "$TMP_ROOT/fail-result.out")" "fake failure"
assert_json_file "$(job_dir_for_work "$fail_work")/metadata.json"
if "$CC_WATCH" status "$fail_job" --cwd "$fail_work" > "$TMP_ROOT/fail-status-default.out"; then
  fail "default failed status should return non-zero"
fi

partial_fail_work="$(new_workdir partial-fail)"
partial_fail_args="$TMP_ROOT/partial-fail.args"
set +e
FAKE_ARGS_LOG="$partial_fail_args" FAKE_BEHAVIOR=partial-fail \
  "$CC_WATCH" run --cwd "$partial_fail_work" --claude "$FAKE_CLAUDE" -- "review only" > "$TMP_ROOT/partial-fail-run.out" 2>&1
partial_fail_code="$?"
set -e
if [ "$partial_fail_code" -ne 42 ]; then
  fail "partial-fail run should return 42, got $partial_fail_code"
fi
partial_fail_dir="$(job_dir_for_work "$partial_fail_work")"
partial_fail_result="$(cat "$partial_fail_dir/result.txt")"
partial_fail_transcript="$(cat "$partial_fail_dir/transcript.md")"
partial_fail_metadata="$(cat "$partial_fail_dir/metadata.md")"
assert_contains "$partial_fail_result" "## Warnings"
assert_contains "$partial_fail_result" "permission denied: tool Write is not allowed"
assert_contains "$partial_fail_result" "## Last assistant text before failure"
assert_contains "$partial_fail_result" "Partial useful review before the socket failed"
assert_contains "$partial_fail_transcript" "Last assistant text before failure"
assert_contains "$partial_fail_transcript" "Partial useful review before the socket failed"
assert_contains "$partial_fail_metadata" "## Warnings"
assert_contains "$partial_fail_metadata" "Permission denied for tool Write"
assert_json_file "$partial_fail_dir/metadata.json"

secret_work="$(new_workdir secret-success)"
secret_args="$TMP_ROOT/secret-success.args"
FAKE_ARGS_LOG="$secret_args" FAKE_BEHAVIOR=secret-success \
  "$CC_WATCH" run --cwd "$secret_work" --claude "$FAKE_CLAUDE" -- "review only" > "$TMP_ROOT/secret-run.out"
secret_dir="$(job_dir_for_work "$secret_work")"
secret_job="$(job_id_for_work "$secret_work")"
secret_run_text="$(cat "$TMP_ROOT/secret-run.out")"
secret_result_text="$(cat "$secret_dir/result.txt")"
secret_transcript_text="$(cat "$secret_dir/transcript.md")"
secret_show_raw="$("$CC_WATCH" show --cwd "$secret_work" "$secret_job" --raw)"
"$CC_WATCH" result "$secret_job" --cwd "$secret_work" --json > "$TMP_ROOT/secret-result.json"
assert_json_file "$TMP_ROOT/secret-result.json"
assert_contains "$(cat "$TMP_ROOT/secret-result.json")" "Authorization: Bearer REDACTED"
assert_not_contains "$(cat "$TMP_ROOT/secret-result.json")" "SECRET123"
assert_contains "$secret_run_text" "Authorization: Bearer REDACTED"
assert_contains "$secret_result_text" "sk-ant-REDACTED"
assert_contains "$secret_result_text" "Authorization: Basic REDACTED"
assert_contains "$secret_result_text" "x-api-key: REDACTED"
assert_contains "$secret_result_text" "token=REDACTED"
assert_contains "$secret_transcript_text" "ANTHROPIC_API_KEY=REDACTED"
assert_contains "$secret_transcript_text" "http_proxy=REDACTED"
assert_contains "$secret_show_raw" "Authorization: Bearer REDACTED"
assert_not_contains "$secret_run_text" "SECRET123"
assert_not_contains "$secret_result_text" "BASICSECRET"
assert_not_contains "$secret_result_text" "HEADERSECRET"
assert_not_contains "$secret_result_text" "secretvalue"
assert_not_contains "$secret_transcript_text" "envsecret"
assert_not_contains "$secret_transcript_text" "user:pass"
assert_not_contains "$secret_show_raw" "SECRET123"
assert_contains "$(cat "$secret_dir/stdout.jsonl")" "SECRET123"

metadata_path_work="$(new_workdir sk-metadata-path)"
metadata_path_args="$TMP_ROOT/sk-metadata-path.args"
metadata_path_title="metadata sk-ant-secretvalue"
FAKE_ARGS_LOG="$metadata_path_args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$metadata_path_work" --claude "$FAKE_CLAUDE" \
  --title "$metadata_path_title" --model "sk-ant-modelsecret" --effort "sk-ant-effortsecret" \
  -- "review only" > "$TMP_ROOT/sk-metadata-path.out"
metadata_path_job="$(job_id_for_work "$metadata_path_work")"
metadata_path_dir="$(job_dir_for_work "$metadata_path_work")"
metadata_path_text="$(cat "$metadata_path_dir/metadata.json")"
assert_json_file "$metadata_path_dir/metadata.json"
assert_contains "$metadata_path_text" "\"cwd\": \"$metadata_path_work\""
assert_contains "$metadata_path_text" "sk-metadata-path"
assert_contains "$metadata_path_text" "metadata sk-ant-REDACTED"
assert_contains "$metadata_path_text" "\"model\": \"sk-ant-REDACTED\""
assert_contains "$metadata_path_text" "\"effort\": \"sk-ant-REDACTED\""
assert_not_contains "$metadata_path_text" "sk-REDACTED"
assert_not_contains "$metadata_path_text" "sk-ant-secretvalue"
assert_not_contains "$metadata_path_text" "modelsecret"
assert_not_contains "$metadata_path_text" "effortsecret"
metadata_show_text="$("$CC_WATCH" show --cwd "$metadata_path_work" "$metadata_path_job" --metadata)"
[ "$metadata_show_text" = "$metadata_path_text" ] || fail "show --metadata should print stored metadata without extra redaction"
"$CC_WATCH" result "$metadata_path_job" --cwd "$metadata_path_work" --json > "$TMP_ROOT/sk-metadata-result.json"
"$CC_WATCH" list --cwd "$metadata_path_work" --json > "$TMP_ROOT/sk-metadata-list.json"
assert_json_file "$TMP_ROOT/sk-metadata-result.json"
assert_json_file "$TMP_ROOT/sk-metadata-list.json"
assert_contains "$(cat "$TMP_ROOT/sk-metadata-result.json")" "$metadata_path_work"
assert_contains "$(cat "$TMP_ROOT/sk-metadata-list.json")" "$metadata_path_work"
perl -MJSON::PP -e '
  local $/;
  open my $mf, "<", $ARGV[0] or die $!;
  my $metadata = JSON::PP->new->decode(<$mf>);
  open my $rf, "<", $ARGV[1] or die $!;
  my $result = JSON::PP->new->decode(<$rf>);
  open my $lf, "<", $ARGV[2] or die $!;
  my $list = JSON::PP->new->decode(<$lf>);
  die "cwd mismatch\n" unless @$list == 1 && $metadata->{cwd} eq $result->{cwd} && $metadata->{cwd} eq $list->[0]{cwd};
  die "result_path mismatch\n" unless $result->{result_path} eq $list->[0]{result_path};
' "$metadata_path_dir/metadata.json" "$TMP_ROOT/sk-metadata-result.json" "$TMP_ROOT/sk-metadata-list.json" \
  || fail "metadata, result --json, and list --json should agree on structural paths"

secret_fail_work="$(new_workdir secret-fail)"
secret_fail_args="$TMP_ROOT/secret-fail.args"
set +e
FAKE_ARGS_LOG="$secret_fail_args" FAKE_BEHAVIOR=secret-fail \
  "$CC_WATCH" run --cwd "$secret_fail_work" --claude "$FAKE_CLAUDE" -- "review only" > "$TMP_ROOT/secret-fail-run.out" 2>&1
secret_fail_code="$?"
set -e
if [ "$secret_fail_code" -eq 0 ]; then
  fail "secret-fail run should fail"
fi
secret_fail_text="$(cat "$TMP_ROOT/secret-fail-run.out")"
assert_contains "$secret_fail_text" "Authorization: Bearer REDACTED"
assert_contains "$secret_fail_text" "Proxy-Authorization: Basic REDACTED"
assert_contains "$secret_fail_text" "x-api-key: REDACTED"
assert_contains "$secret_fail_text" "sk-ant-REDACTED"
assert_contains "$secret_fail_text" "api_key=REDACTED"
assert_contains "$secret_fail_text" "HTTP_PROXY=REDACTED"
assert_contains "$secret_fail_text" "https_proxy=REDACTED"
assert_not_contains "$secret_fail_text" "FAILSECRET"
assert_not_contains "$secret_fail_text" "failsecret"
assert_not_contains "$secret_fail_text" "failkey"
assert_not_contains "$secret_fail_text" "lower-proxy-secret"

doctor_work="$(new_workdir doctor)"
doctor_out="$TMP_ROOT/doctor.out"
doctor_args="$TMP_ROOT/doctor.args"
mkdir -p "$doctor_work/.cc-watch/cc-doctor-stale"
printf '%s\n' "cc-doctor-stale" > "$doctor_work/.cc-watch/cc-doctor-stale/job_id"
mark_job_stale "$doctor_work/.cc-watch/cc-doctor-stale" "running-quiet" "2147483647" "" "" "1"
mkdir -p "$doctor_work/.cc-watch/cc-doctor-empty-pids"
printf '%s\n' "cc-doctor-empty-pids" > "$doctor_work/.cc-watch/cc-doctor-empty-pids/job_id"
mark_job_stale "$doctor_work/.cc-watch/cc-doctor-empty-pids" "starting" "" "" "" "1"
ANTHROPIC_API_KEY=dummy-secret FAKE_ARGS_LOG="$doctor_args" \
  "$CC_WATCH" doctor --cwd "$doctor_work" --claude "$FAKE_CLAUDE" > "$doctor_out"
doctor_text="$(cat "$doctor_out")"
assert_contains "$doctor_text" "cc_watch_version=0.5.6"
assert_contains "$doctor_text" "claude_path=$FAKE_CLAUDE"
assert_contains "$doctor_text" "claude_version=fake claude 0.0.0"
assert_contains "$doctor_text" "flag_print=yes"
assert_contains "$doctor_text" "flag_stream_json=yes"
assert_contains "$doctor_text" "flag_tools=yes"
assert_contains "$doctor_text" "flag_strict_mcp_config=yes"
assert_contains "$doctor_text" "flag_no_session_persistence=yes"
assert_contains "$doctor_text" "flag_permission_mode=yes"
assert_contains "$doctor_text" "ANTHROPIC_API_KEY=REDACTED"
assert_not_contains "$doctor_text" "dummy-secret"
assert_contains "$doctor_text" "state_git_ignored=not-git"
assert_contains "$doctor_text" "stale_selected_count=2"
assert_contains "$doctor_text" "stale_skipped_count=0"
assert_contains "$doctor_text" "stale_warning=stale-nonterminal-jobs"
assert_contains "$doctor_text" "stale_repair_command=cc-watch repair-stale --cwd $doctor_work --state-root $doctor_work/.cc-watch --json"

async_work="$(new_workdir async-success)"
async_args="$TMP_ROOT/async-success.args"
async_job="$(FAKE_ARGS_LOG="$async_args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" start --cwd "$async_work" --claude "$FAKE_CLAUDE" -- "review only")"
async_status="$(wait_for_status "$async_work" "$async_job" "finished")"
assert_contains "$async_status" "elapsed="
async_result="$("$CC_WATCH" result "$async_job" --cwd "$async_work")"
assert_contains "$async_result" "fake final review"
async_findings="$("$CC_WATCH" findings "$async_job" --cwd "$async_work")"
assert_contains "$async_findings" "fake final review"

findings_work="$(new_workdir findings)"
findings_args="$TMP_ROOT/findings.args"
findings_title="findings sk-ant-secretvalue"
FAKE_ARGS_LOG="$findings_args" FAKE_BEHAVIOR=findings \
  "$CC_WATCH" run --cwd "$findings_work" --claude "$FAKE_CLAUDE" \
  --title "$findings_title" -- "review only" > "$TMP_ROOT/findings.out"
findings_text="$("$CC_WATCH" findings --cwd "$findings_work" "$findings_title")"
assert_contains "$findings_text" "## Findings"
assert_contains "$findings_text" "### P1: Bug"
assert_contains "$findings_text" "## Not a real heading"
assert_contains "$findings_text" "sk-ant-REDACTED"
assert_not_contains "$findings_text" "sk-ant-secretvalue"
assert_not_contains "$findings_text" "## Appendix"
findings_json_file="$TMP_ROOT/findings.json"
"$CC_WATCH" findings --cwd "$findings_work" --last --json > "$findings_json_file"
assert_json_file "$findings_json_file"
findings_json_text="$(cat "$findings_json_file")"
assert_contains "$findings_json_text" '"heading" : "Findings"'
assert_contains "$findings_json_text" '"title" : "findings sk-ant-REDACTED"'
assert_not_contains "$findings_json_text" "sk-ant-secretvalue"

findings_summary_work="$(new_workdir findings-summary)"
FAKE_ARGS_LOG="$TMP_ROOT/findings-summary.args" FAKE_BEHAVIOR=findings-summary \
  "$CC_WATCH" run --cwd "$findings_summary_work" --claude "$FAKE_CLAUDE" \
  --title "findings summary" -- "review only" > "$TMP_ROOT/findings-summary.out"
findings_summary_text="$("$CC_WATCH" findings --cwd "$findings_summary_work" --last)"
assert_contains "$findings_summary_text" "## Summary"
assert_contains "$findings_summary_text" "## Analysis"
assert_contains "$findings_summary_text" "Substantive analysis body"
assert_not_contains "$findings_summary_text" "Ignored appendix"

empty_list_work="$(new_workdir empty-list)"
empty_list="$("$CC_WATCH" list --cwd "$empty_list_work")"
[ -z "$empty_list" ] || fail "empty list should print nothing"
empty_list_json="$("$CC_WATCH" list --cwd "$empty_list_work" --json)"
[ "$empty_list_json" = "[]" ] || fail "empty list --json should print [], got [$empty_list_json]"

state_work="$(new_workdir state-root)"
state_parent="$state_work/custom-state"
state_args="$TMP_ROOT/state-root.args"
FAKE_ARGS_LOG="$state_args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$state_work" --state-root "$state_parent" --claude "$FAKE_CLAUDE" \
  --title "state root test" -- "review only" > "$TMP_ROOT/state-root.out"
[ ! -d "$state_work/.cc-watch" ] || fail "custom state root should not write default .cc-watch"
[ -d "$state_parent/.cc-watch" ] || fail "custom state root did not create nested .cc-watch"
[ -f "$state_parent/.cc-watch/.gitignore" ] || fail "custom state root missing nested .gitignore"
[ ! -f "$state_parent/.gitignore" ] || fail "custom state root wrote gitignore to user parent dir"
state_job="$(job_id_for_state_parent "$state_parent")"
state_dir="$(job_dir_for_state_parent "$state_parent")"
state_status="$("$CC_WATCH" status "$state_job" --cwd "$state_work" --state-root "$state_parent")"
assert_contains "$state_status" "finished"
assert_not_contains "$state_status" "state_warning"
state_result="$("$CC_WATCH" result "$state_job" --cwd "$state_work" --state-root "$state_parent")"
assert_contains "$state_result" "fake final review"
state_list="$("$CC_WATCH" list --cwd "$state_work" --state-root "$state_parent")"
assert_contains "$state_list" "title=state root test"
state_list_json="$("$CC_WATCH" list --cwd "$state_work" --state-root "$state_parent" --json)"
printf '%s\n' "$state_list_json" > "$TMP_ROOT/state-list.json"
assert_json_file "$TMP_ROOT/state-list.json"
assert_contains "$state_list_json" '"title" : "state root test"'
assert_contains "$state_list_json" "\"state_root\" : \"$state_parent/.cc-watch\""
state_show="$("$CC_WATCH" show --cwd "$state_work" --state-root "$state_parent" --last)"
assert_contains "$state_show" "fake final review"
assert_contains "$(cat "$state_dir/metadata.json")" "\"state_root\": \"$state_parent/.cc-watch\""
assert_contains "$(cat "$state_dir/metadata.json")" '"external_state": "0"'

external_state_work="$(new_workdir external-state)"
external_parent="$TMP_ROOT/outside-state"
if FAKE_ARGS_LOG="$TMP_ROOT/external-denied.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$external_state_work" --state-root "$external_parent" \
  --claude "$FAKE_CLAUDE" -- "review only" >/dev/null 2>&1; then
  fail "external state root without allow flag should fail"
fi
[ ! -e "$external_parent" ] || fail "denied external state root should not be created"
FAKE_ARGS_LOG="$TMP_ROOT/external-allowed.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$external_state_work" --state-root "$external_parent" \
  --allow-external-state-root --claude "$FAKE_CLAUDE" -- "review only" > "$TMP_ROOT/external-allowed.out"
external_job="$(job_id_for_state_parent "$external_parent")"
external_dir="$(job_dir_for_state_parent "$external_parent")"
external_result="$("$CC_WATCH" result "$external_job" --cwd "$external_state_work" --state-root "$external_parent" --allow-external-state-root)"
assert_contains "$external_result" "fake final review"
assert_contains "$(cat "$external_dir/metadata.json")" '"external_state": "1"'
external_doctor="$("$CC_WATCH" doctor --cwd "$external_state_work" --state-root "$external_parent" --allow-external-state-root --claude "$FAKE_CLAUDE")"
assert_contains "$external_doctor" "state_external=1"
assert_contains "$external_doctor" "state_warning=external-state-root"

list_text="$("$CC_WATCH" list --cwd "$async_work")"
assert_contains "$list_text" "job=$async_job"
assert_contains "$list_text" "status=finished"
assert_contains "$list_text" "session_resumable=no"
list_json="$("$CC_WATCH" list --cwd "$async_work" --json)"
printf '%s\n' "$list_json" > "$TMP_ROOT/list.json"
assert_json_file "$TMP_ROOT/list.json"
assert_contains "$list_json" "\"job_id\" : \"$async_job\""
assert_contains "$list_json" '"status" : "finished"'
assert_contains "$list_json" '"exit_code" : 0'
assert_contains "$list_json" '"session_resumable" : false'
assert_contains "$list_json" "\"result_path\" : \"$async_work/.cc-watch/$async_job/result.txt\""
assert_contains "$list_json" "\"transcript_path\" : \"$async_work/.cc-watch/$async_job/transcript.md\""

order_work="$(new_workdir list-order)"
FAKE_ARGS_LOG="$TMP_ROOT/list-order-old.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$order_work" --claude "$FAKE_CLAUDE" \
  --title "older job" -- "review only" > "$TMP_ROOT/list-order-old.out"
order_old_job="$(job_id_for_work "$order_work")"
order_old_dir="$order_work/.cc-watch/$order_old_job"
FAKE_ARGS_LOG="$TMP_ROOT/list-order-new.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$order_work" --claude "$FAKE_CLAUDE" \
  --title "newer job" -- "review only" > "$TMP_ROOT/list-order-new.out"
order_new_job="$(find "$order_work/.cc-watch" -maxdepth 2 -name job_id -exec cat {} \; | grep -v "^$order_old_job$")"
order_new_dir="$order_work/.cc-watch/$order_new_job"
printf '100\n' > "$order_old_dir/started_at"
printf '200\n' > "$order_new_dir/started_at"
order_json_file="$TMP_ROOT/list-order.json"
"$CC_WATCH" list --cwd "$order_work" --json > "$order_json_file"
assert_json_file "$order_json_file"
perl -MJSON::PP -e '
  local $/;
  my $jobs = JSON::PP->new->decode(<STDIN>);
  die "expected newest first\n" unless @$jobs == 2 && $jobs->[0]{job_id} eq $ARGV[0] && $jobs->[1]{job_id} eq $ARGV[1];
' "$order_new_job" "$order_old_job" < "$order_json_file" || fail "list --json should be newest first"

secret_list_work="$(new_workdir secret-list)"
secret_list_args="$TMP_ROOT/secret-list.args"
FAKE_ARGS_LOG="$secret_list_args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$secret_list_work" --claude "$FAKE_CLAUDE" \
  --title "sk-ant-secretvalue" -- "review only" > "$TMP_ROOT/secret-list.out"
secret_list_json="$("$CC_WATCH" list --cwd "$secret_list_work" --json)"
assert_contains "$secret_list_json" "sk-ant-REDACTED"
assert_not_contains "$secret_list_json" "sk-ant-secretvalue"

sk_path_work="$(new_workdir sk-path-secret)"
sk_path_args="$TMP_ROOT/sk-path-secret.args"
FAKE_ARGS_LOG="$sk_path_args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$sk_path_work" --claude "$FAKE_CLAUDE" \
  --title "path redaction guard" -- "review only" > "$TMP_ROOT/sk-path-secret.out"
sk_path_json="$("$CC_WATCH" list --cwd "$sk_path_work" --json)"
assert_contains "$sk_path_json" "$sk_path_work"
assert_contains "$sk_path_json" "sk-path-secret"
assert_not_contains "$sk_path_json" "sk-REDACTED"

manage_work="$(new_workdir manage)"
for i in 1 2 3; do
  FAKE_ARGS_LOG="$TMP_ROOT/manage-$i.args" FAKE_BEHAVIOR=success \
    "$CC_WATCH" run --cwd "$manage_work" --claude "$FAKE_CLAUDE" \
    --title "manage $i" -- "review only" > "$TMP_ROOT/manage-$i.out"
done
manage_count="$(count_job_dirs_for_work "$manage_work")"
[ "$manage_count" -eq 3 ] || fail "expected 3 manage jobs, got $manage_count"
archive_dry="$("$CC_WATCH" archive --cwd "$manage_work")"
assert_contains "$archive_dry" "cc-watch archive dry_run=yes selected=3"
archive_yes="$("$CC_WATCH" archive --cwd "$manage_work" --keep 1 --yes)"
assert_contains "$archive_yes" "cc-watch archive dry_run=no selected=2"
assert_contains "$archive_yes" "archive_path="
archive_path="$(printf '%s\n' "$archive_yes" | awk -F= '/^archive_path=/{print $2}')"
[ -f "$archive_path" ] || fail "archive file missing: $archive_path"
archive_listing="$(tar -tzf "$archive_path")"
assert_contains "$archive_listing" "cc-"
if "$CC_WATCH" prune --cwd "$manage_work" --yes >/dev/null 2>&1; then
  fail "prune --yes without selector should fail"
fi
if "$CC_WATCH" prune --cwd "$manage_work" --keep 0 --yes >/dev/null 2>&1; then
  fail "prune --keep 0 --yes should fail"
fi
if "$CC_WATCH" prune --cwd "$manage_work" --older-than-days 0 --yes >/dev/null 2>&1; then
  fail "prune --older-than-days 0 --yes should fail"
fi
prune_dry="$("$CC_WATCH" prune --cwd "$manage_work" --keep 1)"
assert_contains "$prune_dry" "cc-watch prune dry_run=yes selected=2"
manage_count_after_dry="$(count_job_dirs_for_work "$manage_work")"
[ "$manage_count_after_dry" -eq 3 ] || fail "dry-run prune should keep 3 jobs, got $manage_count_after_dry"
prune_yes="$("$CC_WATCH" prune --cwd "$manage_work" --keep 1 --yes)"
assert_contains "$prune_yes" "cc-watch prune dry_run=no selected=2"
assert_contains "$prune_yes" "pruned=2"
manage_count_after_prune="$(count_job_dirs_for_work "$manage_work")"
[ "$manage_count_after_prune" -eq 1 ] || fail "prune --keep 1 should leave 1 job, got $manage_count_after_prune"

running_prune_work="$(new_workdir running-prune)"
FAKE_ARGS_LOG="$TMP_ROOT/running-prune-finished.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$running_prune_work" --claude "$FAKE_CLAUDE" -- "review only" > "$TMP_ROOT/running-prune-finished.out"
running_prune_pid_file="$TMP_ROOT/running-prune.pid"
running_prune_args="$TMP_ROOT/running-prune.args"
running_prune_job="$(FAKE_ARGS_LOG="$running_prune_args" FAKE_BEHAVIOR=slow FAKE_PID_FILE="$running_prune_pid_file" \
  "$CC_WATCH" start --cwd "$running_prune_work" --claude "$FAKE_CLAUDE" -- "review only")"
wait_for_file "$running_prune_pid_file"
wait_for_status "$running_prune_work" "$running_prune_job" "running-" >/dev/null
repair_live_text="$("$CC_WATCH" repair-stale --cwd "$running_prune_work" --yes)"
assert_contains "$repair_live_text" "cc-watch repair-stale dry_run=no selected=0"
assert_contains "$repair_live_text" "skipped job=$running_prune_job"
assert_contains "$repair_live_text" "reason=process-alive"
repair_live_json="$("$CC_WATCH" repair-stale --cwd "$running_prune_work" --json --yes)"
printf '%s\n' "$repair_live_json" > "$TMP_ROOT/repair-stale-live.json"
assert_json_file "$TMP_ROOT/repair-stale-live.json"
perl -MJSON::PP -e '
  local $/;
  my $payload = JSON::PP->new->decode(<STDIN>);
  die "selected count mismatch\n" unless $payload->{selected_count} == 0;
  die "repaired count mismatch\n" unless $payload->{repaired_count} == 0;
  die "records mismatch\n" unless @{$payload->{records}} == 1;
  die "apply records should be empty\n" unless @{$payload->{apply_records}} == 0;
  my $record = $payload->{records}[0];
  die "job mismatch\n" unless $record->{job_id} eq $ARGV[0];
  die "kind mismatch\n" unless $record->{kind} eq "skipped";
  die "reason mismatch\n" unless $record->{reason} eq "process-alive";
' "$running_prune_job" < "$TMP_ROOT/repair-stale-live.json" || fail "repair-stale live --json payload mismatch"
running_prune_text="$("$CC_WATCH" prune --cwd "$running_prune_work" --all-terminal --yes)"
assert_contains "$running_prune_text" "pruned=1"
[ -d "$running_prune_work/.cc-watch/$running_prune_job" ] || fail "running job should survive prune --all-terminal"
"$CC_WATCH" cancel "$running_prune_job" --cwd "$running_prune_work" >/dev/null

repair_empty_work="$(new_workdir repair-stale-empty)"
repair_empty_json="$("$CC_WATCH" repair-stale --cwd "$repair_empty_work" --json)"
printf '%s\n' "$repair_empty_json" > "$TMP_ROOT/repair-stale-empty.json"
assert_json_file "$TMP_ROOT/repair-stale-empty.json"
perl -MJSON::PP -e '
  local $/;
  my $payload = JSON::PP->new->decode(<STDIN>);
  die "dry_run should be true\n" unless $payload->{dry_run};
  die "selected count mismatch\n" unless $payload->{selected_count} == 0;
  die "repaired count mismatch\n" unless $payload->{repaired_count} == 0;
  die "records should be empty\n" unless @{$payload->{records}} == 0;
  die "apply records should be empty\n" unless @{$payload->{apply_records}} == 0;
' < "$TMP_ROOT/repair-stale-empty.json" || fail "repair-stale empty --json payload mismatch"

repair_work="$(new_workdir repair-stale)"
FAKE_ARGS_LOG="$TMP_ROOT/repair-stale.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$repair_work" --claude "$FAKE_CLAUDE" \
  --title "sk-ant-secretvalue" -- "review only" > "$TMP_ROOT/repair-stale.out"
repair_job="$(job_id_for_work "$repair_work")"
repair_dir="$(job_dir_for_work "$repair_work")"
mark_job_stale "$repair_dir" "running-quiet" "2147483647" "" "" "1"
repair_dry="$("$CC_WATCH" repair-stale --cwd "$repair_work")"
assert_contains "$repair_dry" "cc-watch repair-stale dry_run=yes selected=1"
assert_contains "$repair_dry" "selected job=$repair_job"
assert_contains "$repair_dry" "reason=dead-pids"
repair_dry_json="$("$CC_WATCH" repair-stale --cwd "$repair_work" --json)"
printf '%s\n' "$repair_dry_json" > "$TMP_ROOT/repair-stale-dry.json"
assert_json_file "$TMP_ROOT/repair-stale-dry.json"
perl -MJSON::PP -e '
  local $/;
  my $payload = JSON::PP->new->decode(<STDIN>);
  die "dry_run should be true\n" unless $payload->{dry_run};
  die "selected count mismatch\n" unless $payload->{selected_count} == 1;
  die "repaired count mismatch\n" unless $payload->{repaired_count} == 0;
  die "records mismatch\n" unless @{$payload->{records}} == 1;
  die "apply records should be empty\n" unless @{$payload->{apply_records}} == 0;
  my $record = $payload->{records}[0];
  die "job mismatch\n" unless $record->{job_id} eq $ARGV[0];
  die "kind mismatch\n" unless $record->{kind} eq "selected";
  die "reason mismatch\n" unless $record->{reason} eq "dead-pids";
' "$repair_job" < "$TMP_ROOT/repair-stale-dry.json" || fail "repair-stale --json dry-run payload mismatch"
[ "$(cat "$repair_dir/status")" = "running-quiet" ] || fail "repair-stale dry-run mutated status"
repair_yes="$("$CC_WATCH" repair-stale --cwd "$repair_work" --yes)"
assert_contains "$repair_yes" "cc-watch repair-stale dry_run=no selected=1"
assert_contains "$repair_yes" "repaired job=$repair_job status=failed reason=dead-pids"
assert_contains "$repair_yes" "repaired=1"
[ "$(cat "$repair_dir/status")" = "failed" ] || fail "repair-stale should mark job failed"
[ "$(cat "$repair_dir/exit_code")" = "1" ] || fail "repair-stale should write exit_code=1"
assert_json_file "$repair_dir/metadata.json"
assert_contains "$(cat "$repair_dir/metadata.json")" '"status": "failed"'
assert_contains "$(cat "$repair_dir/result.txt")" "repair-stale found no live worker"
assert_contains "$(cat "$repair_dir/result.txt")" "NO FINAL RESULT"
assert_contains "$(cat "$repair_dir/transcript.md")" "repair-stale found no live worker"
assert_not_contains "$(cat "$repair_dir/result.txt")" "sk-ant-secretvalue"
if repair_result="$("$CC_WATCH" result "$repair_job" --cwd "$repair_work" 2>&1)"; then
  fail "repair-stale failed job result should exit non-zero"
else
  repair_result_code="$?"
fi
[ "$repair_result_code" -eq 1 ] || fail "repair-stale result should exit 1, got $repair_result_code"
assert_contains "$repair_result" "status: \`failed\`"
repair_second="$("$CC_WATCH" repair-stale --cwd "$repair_work" --yes)"
assert_contains "$repair_second" "cc-watch repair-stale dry_run=no selected=0"
assert_contains "$repair_second" "repaired=0"
repair_prune="$("$CC_WATCH" prune --cwd "$repair_work" --all-terminal --yes)"
assert_contains "$repair_prune" "pruned=1"
[ "$(count_job_dirs_for_work "$repair_work")" -eq 0 ] || fail "repair-stale job should prune after terminal repair"

repair_recent_work="$(new_workdir repair-stale-recent)"
FAKE_ARGS_LOG="$TMP_ROOT/repair-stale-recent.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$repair_recent_work" --claude "$FAKE_CLAUDE" -- "review only" > "$TMP_ROOT/repair-stale-recent.out"
repair_recent_job="$(job_id_for_work "$repair_recent_work")"
repair_recent_dir="$(job_dir_for_work "$repair_recent_work")"
mark_job_stale "$repair_recent_dir" "starting" "" "" "" "$(date +%s)"
repair_recent="$("$CC_WATCH" repair-stale --cwd "$repair_recent_work" --grace-seconds 60 --yes)"
assert_contains "$repair_recent" "cc-watch repair-stale dry_run=no selected=0"
assert_contains "$repair_recent" "skipped job=$repair_recent_job"
assert_contains "$repair_recent" "reason=within-grace"
[ "$(cat "$repair_recent_dir/status")" = "starting" ] || fail "recent starting job should stay non-terminal"

repair_old_work="$(new_workdir repair-stale-old-nopid)"
FAKE_ARGS_LOG="$TMP_ROOT/repair-stale-old.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$repair_old_work" --claude "$FAKE_CLAUDE" -- "review only" > "$TMP_ROOT/repair-stale-old.out"
repair_old_job="$(job_id_for_work "$repair_old_work")"
repair_old_dir="$(job_dir_for_work "$repair_old_work")"
mark_job_stale "$repair_old_dir" "starting" "" "" "" "1"
mkdir -p "$repair_old_work/.cc-watch/cc-not-a-job"
repair_old="$("$CC_WATCH" repair-stale --cwd "$repair_old_work" --grace-seconds 1 --yes)"
assert_contains "$repair_old" "selected job=$repair_old_job"
assert_contains "$repair_old" "reason=no-pid-after-grace"
assert_contains "$repair_old" "repaired=1"
[ "$(cat "$repair_old_dir/status")" = "failed" ] || fail "old no-pid starting job should be repaired"

repair_missing_status_work="$(new_workdir repair-stale-missing-status)"
FAKE_ARGS_LOG="$TMP_ROOT/repair-stale-missing-status.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$repair_missing_status_work" --claude "$FAKE_CLAUDE" -- "review only" > "$TMP_ROOT/repair-stale-missing-status.out"
repair_missing_status_job="$(job_id_for_work "$repair_missing_status_work")"
repair_missing_status_dir="$(job_dir_for_work "$repair_missing_status_work")"
mark_job_stale "$repair_missing_status_dir" "" "" "" "" "1"
repair_missing_status="$("$CC_WATCH" repair-stale --cwd "$repair_missing_status_work" --yes)"
assert_contains "$repair_missing_status" "selected job=$repair_missing_status_job"
assert_contains "$repair_missing_status" "reason=missing-status"
assert_contains "$repair_missing_status" "repaired=1"
if "$CC_WATCH" repair-stale --cwd "$repair_missing_status_work" --grace-seconds nope >/dev/null 2>&1; then
  fail "repair-stale --grace-seconds with a non-integer should fail"
fi

repair_json_work="$(new_workdir repair-stale-json-apply)"
FAKE_ARGS_LOG="$TMP_ROOT/repair-stale-json-apply.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$repair_json_work" --claude "$FAKE_CLAUDE" -- "review only" > "$TMP_ROOT/repair-stale-json-apply.out"
repair_json_job="$(job_id_for_work "$repair_json_work")"
repair_json_dir="$(job_dir_for_work "$repair_json_work")"
mark_job_stale "$repair_json_dir" "running-quiet" "2147483647" "" "" "1"
repair_apply_json="$("$CC_WATCH" repair-stale --cwd "$repair_json_work" --json --yes)"
printf '%s\n' "$repair_apply_json" > "$TMP_ROOT/repair-stale-apply.json"
assert_json_file "$TMP_ROOT/repair-stale-apply.json"
assert_not_contains "$repair_apply_json" "repaired job="
perl -MJSON::PP -e '
  local $/;
  my $payload = JSON::PP->new->decode(<STDIN>);
  die "dry_run should be false\n" if $payload->{dry_run};
  die "selected count mismatch\n" unless $payload->{selected_count} == 1;
  die "repaired count mismatch\n" unless $payload->{repaired_count} == 1;
  die "apply records mismatch\n" unless @{$payload->{apply_records}} == 1;
  my $record = $payload->{apply_records}[0];
  die "job mismatch\n" unless $record->{job_id} eq $ARGV[0];
  die "kind mismatch\n" unless $record->{kind} eq "repaired";
  die "status mismatch\n" unless $record->{status} eq "failed";
  die "reason mismatch\n" unless $record->{reason} eq "dead-pids";
' "$repair_json_job" < "$TMP_ROOT/repair-stale-apply.json" || fail "repair-stale --json --yes payload mismatch"
[ "$(cat "$repair_json_dir/status")" = "failed" ] || fail "repair-stale --json --yes should mark job failed"

repair_json_multi_work="$(new_workdir repair-stale-json-multi)"
FAKE_ARGS_LOG="$TMP_ROOT/repair-stale-json-multi-a.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$repair_json_multi_work" --claude "$FAKE_CLAUDE" -- "review only" > "$TMP_ROOT/repair-stale-json-multi-a.out"
repair_json_multi_a_job="$(job_id_for_work "$repair_json_multi_work")"
repair_json_multi_a_dir="$repair_json_multi_work/.cc-watch/$repair_json_multi_a_job"
FAKE_ARGS_LOG="$TMP_ROOT/repair-stale-json-multi-b.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$repair_json_multi_work" --claude "$FAKE_CLAUDE" -- "review only" > "$TMP_ROOT/repair-stale-json-multi-b.out"
repair_json_multi_b_job="$(find "$repair_json_multi_work/.cc-watch" -maxdepth 2 -name job_id -exec cat {} \; | grep -v "^$repair_json_multi_a_job$")"
repair_json_multi_b_dir="$repair_json_multi_work/.cc-watch/$repair_json_multi_b_job"
mark_job_stale "$repair_json_multi_a_dir" "running-quiet" "2147483647" "" "" "1"
mark_job_stale "$repair_json_multi_b_dir" "running-quiet" "2147483647" "" "" "1"
repair_multi_json="$("$CC_WATCH" repair-stale --cwd "$repair_json_multi_work" --json --yes)"
printf '%s\n' "$repair_multi_json" > "$TMP_ROOT/repair-stale-multi.json"
assert_json_file "$TMP_ROOT/repair-stale-multi.json"
perl -MJSON::PP -e '
  local $/;
  my $payload = JSON::PP->new->decode(<STDIN>);
  die "selected count mismatch\n" unless $payload->{selected_count} == 2;
  die "repaired count mismatch\n" unless $payload->{repaired_count} == 2;
  die "records mismatch\n" unless @{$payload->{records}} == 2;
  die "apply records mismatch\n" unless @{$payload->{apply_records}} == 2;
  my %seen = map { $_->{job_id} => $_->{kind} } @{$payload->{apply_records}};
  die "first job missing\n" unless ($seen{$ARGV[0]} // "") eq "repaired";
  die "second job missing\n" unless ($seen{$ARGV[1]} // "") eq "repaired";
' "$repair_json_multi_a_job" "$repair_json_multi_b_job" < "$TMP_ROOT/repair-stale-multi.json" \
  || fail "repair-stale --json multi-job payload mismatch"

repair_shared_parent="$TMP_ROOT/repair-shared-state"
repair_shared_a_work="$(new_workdir repair-shared-a)"
repair_shared_b_work="$(new_workdir repair-shared-b)"
FAKE_ARGS_LOG="$TMP_ROOT/repair-shared-a.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$repair_shared_a_work" --state-root "$repair_shared_parent" \
  --allow-external-state-root --claude "$FAKE_CLAUDE" -- "review only" > "$TMP_ROOT/repair-shared-a.out"
repair_shared_a_job="$(job_id_for_state_parent "$repair_shared_parent")"
repair_shared_a_dir="$repair_shared_parent/.cc-watch/$repair_shared_a_job"
FAKE_ARGS_LOG="$TMP_ROOT/repair-shared-b.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$repair_shared_b_work" --state-root "$repair_shared_parent" \
  --allow-external-state-root --claude "$FAKE_CLAUDE" -- "review only" > "$TMP_ROOT/repair-shared-b.out"
repair_shared_b_job="$(find "$repair_shared_parent/.cc-watch" -maxdepth 2 -name job_id -exec cat {} \; | grep -v "^$repair_shared_a_job$")"
repair_shared_b_dir="$repair_shared_parent/.cc-watch/$repair_shared_b_job"
mark_job_stale "$repair_shared_a_dir" "running-quiet" "2147483647" "" "" "1"
mark_job_stale "$repair_shared_b_dir" "running-quiet" "2147483647" "" "" "1"
repair_shared="$("$CC_WATCH" repair-stale --cwd "$repair_shared_a_work" --state-root "$repair_shared_parent" --allow-external-state-root --yes)"
assert_contains "$repair_shared" "repaired=2"
perl -MJSON::PP -e '
  local $/;
  open my $af, "<", $ARGV[0] or die "a";
  my $a = JSON::PP->new->decode(<$af>);
  open my $bf, "<", $ARGV[2] or die "b";
  my $b = JSON::PP->new->decode(<$bf>);
  die "a cwd mismatch\n" unless $a->{cwd} eq $ARGV[1];
  die "b cwd mismatch\n" unless $b->{cwd} eq $ARGV[3];
' "$repair_shared_a_dir/metadata.json" "$repair_shared_a_work" \
  "$repair_shared_b_dir/metadata.json" "$repair_shared_b_work" \
  || fail "repair-stale should render metadata with each job cwd"

show_last="$("$CC_WATCH" show --cwd "$async_work" --last)"
assert_contains "$show_last" "fake final review"
show_transcript="$("$CC_WATCH" show --cwd "$async_work" "$async_job" --transcript)"
assert_contains "$show_transcript" "# cc-watch transcript"
assert_contains "$show_transcript" "## Claude"
show_metadata="$("$CC_WATCH" show --cwd "$async_work" "$async_job" --metadata)"
assert_contains "$show_metadata" '"job_id"'
show_raw="$("$CC_WATCH" show --cwd "$async_work" "$async_job" --raw)"
assert_contains "$show_raw" '"type":"result"'

persist_work="$(new_workdir resumable)"
persist_args="$TMP_ROOT/resumable.args"
FAKE_ARGS_LOG="$persist_args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$persist_work" --claude "$FAKE_CLAUDE" \
  --persist-session --title "resumable thread" -- "first review" > "$TMP_ROOT/resumable-first.out"
persist_job="$(job_id_for_work "$persist_work")"
persist_dir="$(job_dir_for_work "$persist_work")"
assert_contains "$(cat "$persist_dir/metadata.json")" '"session_resumable": "yes"'
persist_list="$("$CC_WATCH" list --cwd "$persist_work")"
assert_contains "$persist_list" "title=resumable thread"
assert_contains "$persist_list" "session_resumable=yes"
persist_list_json="$("$CC_WATCH" list --cwd "$persist_work" --json)"
printf '%s\n' "$persist_list_json" > "$TMP_ROOT/persist-list.json"
assert_json_file "$TMP_ROOT/persist-list.json"
assert_contains "$persist_list_json" '"session_resumable" : true'
assert_contains "$persist_list_json" '"session_id" : "11111111-1111-1111-1111-111111111111"'

resume_args_log="$TMP_ROOT/resumable-resume.args"
FAKE_ARGS_LOG="$resume_args_log" FAKE_BEHAVIOR=success \
  "$CC_WATCH" resume --cwd "$persist_work" --claude "$FAKE_CLAUDE" \
  "$persist_job" -- "continue review" > "$TMP_ROOT/resumable-resume.out"
assert_contains "$(tail -1 "$resume_args_log")" "--resume 11111111-1111-1111-1111-111111111111"
assert_not_contains "$(tail -1 "$resume_args_log")" "--no-session-persistence"
resume_job="$(ls "$persist_work/.cc-watch" | grep '^cc-' | sort | tail -1)"
resume_dir="$persist_work/.cc-watch/$resume_job"
assert_contains "$(cat "$resume_dir/metadata.json")" "\"resumed_from\": \"$persist_job\""
assert_contains "$(cat "$resume_dir/result.txt")" "- resumed_from: \`$persist_job\`"
assert_contains "$(cat "$resume_dir/metadata.json")" '"title": "resumable thread"'

resume_title_args_log="$TMP_ROOT/resumable-title-resume.args"
FAKE_ARGS_LOG="$resume_title_args_log" FAKE_BEHAVIOR=success \
  "$CC_WATCH" resume --cwd "$persist_work" --claude "$FAKE_CLAUDE" \
  "resumable thread" -- "continue by title" > "$TMP_ROOT/resumable-title-resume.out"
assert_contains "$(tail -1 "$resume_title_args_log")" "--resume 11111111-1111-1111-1111-111111111111"

resume_mcp_args_log="$TMP_ROOT/resumable-mcp-resume.args"
FAKE_ARGS_LOG="$resume_mcp_args_log" FAKE_BEHAVIOR=success \
  "$CC_WATCH" resume --cwd "$persist_work" --claude "$FAKE_CLAUDE" \
  --mcp-tool mcp__siyuan__siyuan_ping "resumable thread" -- "continue with mcp" > "$TMP_ROOT/resumable-mcp-resume.out"
assert_contains "$(tail -1 "$resume_mcp_args_log")" "--resume 11111111-1111-1111-1111-111111111111"
assert_contains "$(tail -1 "$resume_mcp_args_log")" "--tools Read,Grep,Glob,LS,mcp__siyuan__siyuan_ping"
assert_not_contains "$(tail -1 "$resume_mcp_args_log")" "--strict-mcp-config"

resume_raw_args_log="$TMP_ROOT/resumable-raw-resume.args"
FAKE_ARGS_LOG="$resume_raw_args_log" FAKE_BEHAVIOR=success \
  "$CC_WATCH" resume --cwd "$persist_work" --claude "$FAKE_CLAUDE" \
  22222222-2222-2222-2222-222222222222 -- "continue by raw session" > "$TMP_ROOT/resumable-raw-resume.out"
assert_contains "$(tail -1 "$resume_raw_args_log")" "--resume 22222222-2222-2222-2222-222222222222"

non_persist_work="$(new_workdir nonpersist-resume)"
non_persist_args="$TMP_ROOT/nonpersist.args"
FAKE_ARGS_LOG="$non_persist_args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" run --cwd "$non_persist_work" --claude "$FAKE_CLAUDE" \
  --title "not resumable" -- "first review" > "$TMP_ROOT/nonpersist-first.out"
non_persist_job="$(job_id_for_work "$non_persist_work")"
set +e
FAKE_ARGS_LOG="$TMP_ROOT/nonpersist-resume.args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" resume --cwd "$non_persist_work" --claude "$FAKE_CLAUDE" \
  "$non_persist_job" -- "should not spawn" > "$TMP_ROOT/nonpersist-resume.out" 2>&1
non_persist_resume_code="$?"
set -e
if [ "$non_persist_resume_code" -eq 0 ]; then
  fail "resume from default non-persistent job should fail"
fi
assert_contains "$(cat "$TMP_ROOT/nonpersist-resume.out")" "--persist-session"
if [ -f "$TMP_ROOT/nonpersist-resume.args" ]; then
  fail "non-persistent resume spawned Claude"
fi

cancel_work="$(new_workdir async-cancel)"
cancel_args="$TMP_ROOT/async-cancel.args"
cancel_pid_file="$TMP_ROOT/async-cancel.pid"
cancel_job="$(FAKE_ARGS_LOG="$cancel_args" FAKE_BEHAVIOR=slow FAKE_PID_FILE="$cancel_pid_file" \
  "$CC_WATCH" start --cwd "$cancel_work" --claude "$FAKE_CLAUDE" -- "review only")"
wait_for_file "$cancel_pid_file"
cancel_fake_pid="$(cat "$cancel_pid_file")"
wait_for_status "$cancel_work" "$cancel_job" "running-" >/dev/null
running_list_json="$("$CC_WATCH" list --cwd "$cancel_work" --json)"
printf '%s\n' "$running_list_json" > "$TMP_ROOT/running-list.json"
assert_json_file "$TMP_ROOT/running-list.json"
assert_contains "$running_list_json" "\"job_id\" : \"$cancel_job\""
assert_contains "$running_list_json" '"status" : "running-'
assert_contains "$running_list_json" '"exit_code" : null'
set +e
"$CC_WATCH" findings "$cancel_job" --cwd "$cancel_work" > "$TMP_ROOT/running-findings.out" 2>&1
running_findings_code="$?"
set -e
if [ "$running_findings_code" -ne 2 ]; then
  fail "running findings should return 2, got $running_findings_code"
fi
assert_contains "$(cat "$TMP_ROOT/running-findings.out")" "running-"
set +e
"$CC_WATCH" findings "$cancel_job" --cwd "$cancel_work" --json > "$TMP_ROOT/running-findings.json" 2>&1
running_findings_json_code="$?"
set -e
if [ "$running_findings_json_code" -ne 2 ]; then
  fail "running findings --json should return 2, got $running_findings_json_code"
fi
assert_json_file "$TMP_ROOT/running-findings.json"
assert_contains "$(cat "$TMP_ROOT/running-findings.json")" '"sections" : []'
set +e
"$CC_WATCH" result "$cancel_job" --cwd "$cancel_work" --json > "$TMP_ROOT/running-result.json" 2>&1
running_result_code="$?"
set -e
if [ "$running_result_code" -ne 2 ]; then
  fail "running result --json should return 2, got $running_result_code"
fi
assert_json_file "$TMP_ROOT/running-result.json"
assert_contains "$(cat "$TMP_ROOT/running-result.json")" '"exit_code" : null'
assert_contains "$(cat "$TMP_ROOT/running-result.json")" '"result_text" : ""'
if ! "$CC_WATCH" status "$cancel_job" --cwd "$cancel_work" > "$TMP_ROOT/cancel-status-default.out"; then
  fail "default running status should return zero"
fi
if "$CC_WATCH" status "$cancel_job" --cwd "$cancel_work" --strict-exit > "$TMP_ROOT/cancel-status-strict.out"; then
  fail "strict running status should return non-zero"
fi
cancel_text="$("$CC_WATCH" cancel "$cancel_job" --cwd "$cancel_work")"
assert_contains "$cancel_text" "canceled job=$cancel_job"
cancel_dir="$(job_dir_for_work "$cancel_work")"
assert_contains "$(cat "$cancel_dir/result.txt")" "NO FINAL RESULT"
assert_contains "$(cat "$cancel_dir/metadata.json")" '"status": "canceled"'
assert_json_file "$cancel_dir/metadata.json"
cancel_status="$("$CC_WATCH" status "$cancel_job" --cwd "$cancel_work" || true)"
assert_contains "$cancel_status" "canceled"
set +e
"$CC_WATCH" result "$cancel_job" --cwd "$cancel_work" > "$TMP_ROOT/cancel-result.out" 2>&1
cancel_result_code="$?"
set -e
if [ "$cancel_result_code" -eq 0 ]; then
  fail "cancel result command should return non-zero"
fi
if [ "$cancel_result_code" -ne 130 ]; then
  fail "cancel result command should return 130, got $cancel_result_code"
fi
assert_contains "$(cat "$TMP_ROOT/cancel-result.out")" "NO FINAL RESULT"
assert_contains "$(cat "$TMP_ROOT/cancel-result.out")" "canceled"
if kill -0 "$cancel_fake_pid" 2>/dev/null; then
  fail "cancel left fake Claude process alive: $cancel_fake_pid"
fi

printf 'test_cc_watch ok\n'
