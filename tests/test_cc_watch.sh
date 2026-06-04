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

error_result_work="$(new_workdir error-result)"
error_result_args="$TMP_ROOT/error-result.args"
if FAKE_ARGS_LOG="$error_result_args" FAKE_BEHAVIOR=error-result \
  "$CC_WATCH" run --cwd "$error_result_work" --claude "$FAKE_CLAUDE" -- "review only" >/dev/null 2>&1; then
  fail "error-result run should fail"
fi

partial_result_args="$(run_success_with_behavior partial-result partial-result)"
assert_contains "$partial_result_args" "--tools Read,Grep,Glob,LS"

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

fail_work="$(new_workdir fail)"
fail_args="$TMP_ROOT/fail.args"
if FAKE_ARGS_LOG="$fail_args" FAKE_BEHAVIOR=fail \
  "$CC_WATCH" run --cwd "$fail_work" --claude "$FAKE_CLAUDE" -- "review only" >/dev/null 2>&1; then
  fail "non-zero Claude run should fail"
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
cancel_text="$("$CC_WATCH" cancel "$cancel_job" --cwd "$cancel_work")"
assert_contains "$cancel_text" "canceled job=$cancel_job"
cancel_status="$("$CC_WATCH" status "$cancel_job" --cwd "$cancel_work" || true)"
assert_contains "$cancel_status" "canceled"
if kill -0 "$cancel_fake_pid" 2>/dev/null; then
  fail "cancel left fake Claude process alive: $cancel_fake_pid"
fi

printf 'test_cc_watch ok\n'
