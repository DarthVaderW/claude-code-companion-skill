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
  fail)
    printf 'fake failure\n' >&2
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

new_workdir() {
  local dir="$TMP_ROOT/work-$1"
  mkdir -p "$dir"
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
  assert_contains "$(cat "$(job_dir_for_work "$work")/metadata.json")" '"status": "finished"'
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

allow_bash_args="$(run_success allow-bash --allow-bash)"
assert_contains "$allow_bash_args" "--tools Read,Grep,Glob,LS,Bash"
assert_contains "$allow_bash_args" "--strict-mcp-config"

allow_mcp_args="$(run_success allow-mcp --allow-mcp)"
assert_contains "$allow_mcp_args" "--tools Read,Grep,Glob,LS"
assert_not_contains "$allow_mcp_args" "--strict-mcp-config"

read_write_args="$(run_success read-write --read-write)"
assert_not_contains "$read_write_args" "--tools"
assert_contains "$read_write_args" "--strict-mcp-config"

resume_args="$(run_success resume --resume 11111111-1111-1111-1111-111111111111)"
assert_contains "$resume_args" "--resume 11111111-1111-1111-1111-111111111111"
assert_not_contains "$resume_args" "--no-session-persistence"

continue_args="$(run_success continue --continue)"
assert_contains "$continue_args" "--continue"
assert_not_contains "$continue_args" "--no-session-persistence"

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
assert_contains "$(cat "$(job_dir_for_work "$no_result_work")/metadata.json")" '"status": "failed"'
assert_json_file "$(job_dir_for_work "$no_result_work")/metadata.json"
no_result_status="$("$CC_WATCH" status "$no_result_job" --cwd "$no_result_work" || true)"
assert_contains "$no_result_status" "exit_code=1"

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

doctor_work="$(new_workdir doctor)"
doctor_out="$TMP_ROOT/doctor.out"
doctor_args="$TMP_ROOT/doctor.args"
ANTHROPIC_API_KEY=dummy-secret FAKE_ARGS_LOG="$doctor_args" \
  "$CC_WATCH" doctor --cwd "$doctor_work" --claude "$FAKE_CLAUDE" > "$doctor_out"
doctor_text="$(cat "$doctor_out")"
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

async_work="$(new_workdir async-success)"
async_args="$TMP_ROOT/async-success.args"
async_job="$(FAKE_ARGS_LOG="$async_args" FAKE_BEHAVIOR=success \
  "$CC_WATCH" start --cwd "$async_work" --claude "$FAKE_CLAUDE" -- "review only")"
async_status="$(wait_for_status "$async_work" "$async_job" "finished")"
assert_contains "$async_status" "elapsed="
async_result="$("$CC_WATCH" result "$async_job" --cwd "$async_work")"
assert_contains "$async_result" "fake final review"

cancel_work="$(new_workdir async-cancel)"
cancel_args="$TMP_ROOT/async-cancel.args"
cancel_pid_file="$TMP_ROOT/async-cancel.pid"
cancel_job="$(FAKE_ARGS_LOG="$cancel_args" FAKE_BEHAVIOR=slow FAKE_PID_FILE="$cancel_pid_file" \
  "$CC_WATCH" start --cwd "$cancel_work" --claude "$FAKE_CLAUDE" -- "review only")"
wait_for_file "$cancel_pid_file"
cancel_fake_pid="$(cat "$cancel_pid_file")"
wait_for_status "$cancel_work" "$cancel_job" "running-" >/dev/null
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
