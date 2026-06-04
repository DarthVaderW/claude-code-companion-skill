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

case "${FAKE_BEHAVIOR:-success}" in
  success)
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"11111111-1111-1111-1111-111111111111"}'
    printf '%s\n' '{"type":"result","subtype":"success","session_id":"11111111-1111-1111-1111-111111111111","result":"fake final review"}'
    ;;
  no-result)
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"11111111-1111-1111-1111-111111111111"}'
    ;;
  fail)
    printf 'fake failure\n' >&2
    exit 42
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

new_workdir() {
  local dir="$TMP_ROOT/work-$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

run_success() {
  local label="$1"
  shift
  local work args_log output
  work="$(new_workdir "$label")"
  args_log="$TMP_ROOT/$label.args"
  output="$TMP_ROOT/$label.out"
  FAKE_ARGS_LOG="$args_log" FAKE_BEHAVIOR=success \
    "$CC_WATCH" run --cwd "$work" --claude "$FAKE_CLAUDE" "$@" -- "review only" > "$output"
  assert_contains "$(cat "$output")" "fake final review"
  [ -f "$work/.cc-watch/.gitignore" ] || fail "missing state .gitignore"
  tail -1 "$args_log"
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

fail_work="$(new_workdir fail)"
fail_args="$TMP_ROOT/fail.args"
if FAKE_ARGS_LOG="$fail_args" FAKE_BEHAVIOR=fail \
  "$CC_WATCH" run --cwd "$fail_work" --claude "$FAKE_CLAUDE" -- "review only" >/dev/null 2>&1; then
  fail "non-zero Claude run should fail"
fi

printf 'test_cc_watch ok\n'
