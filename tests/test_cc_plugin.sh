#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC_PLUGIN="$ROOT/claude-code-companion/scripts/cc-plugin"
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

if [ "${1:-}" != "plugin" ]; then
  printf 'unexpected command: %s\n' "$*" >&2
  exit 98
fi

case "${2:-}" in
  --help)
    printf 'Usage: fake claude plugin list|versions|marketplace|update\n'
    ;;
  list)
    printf 'claude-code-companion 0.4.0 enabled\n'
    printf 'siyuan-mcp 0.2.3 enabled Authorization: Bearer LISTSECRET Authorization: Basic BASICLIST x-api-key: HEADERLIST http_proxy=http://user:pass@proxy\n'
    ;;
  versions)
    if [ "${FAKE_VERSIONS_UNAVAILABLE:-0}" = "1" ]; then
      printf "error: unknown command 'versions'\n" >&2
      exit 1
    fi
    printf 'claude-code-companion installed=0.4.0 latest=0.4.1\n'
    printf 'siyuan-mcp installed=0.2.3 latest=0.2.4 sk-ant-versionsecret\n'
    ;;
  marketplace|update)
    printf 'mutating verb should not be called: %s\n' "$*" >&2
    exit 77
    ;;
  *)
    printf 'unknown plugin command: %s\n' "${2:-}" >&2
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

new_workdir() {
  local dir="$TMP_ROOT/work-$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

latest_plugin_archive() {
  local state_parent="$1"
  ls -d "$state_parent/.cc-watch/plugin-admin"/* 2>/dev/null | sort | tail -1
}

doctor_work="$(new_workdir doctor)"
doctor_args="$TMP_ROOT/doctor.args"
doctor_out="$(FAKE_ARGS_LOG="$doctor_args" "$CC_PLUGIN" doctor --cwd "$doctor_work" --claude "$FAKE_CLAUDE")"
doctor_archive="$(latest_plugin_archive "$doctor_work")"
assert_contains "$doctor_out" "plugin_command=yes"
assert_contains "$doctor_out" "read-only doctor"
assert_json_file "$doctor_archive/metadata.json"
assert_contains "$(cat "$doctor_archive/command.txt")" "cc-plugin doctor"

list_work="$(new_workdir list)"
list_args="$TMP_ROOT/list.args"
list_out="$(FAKE_ARGS_LOG="$list_args" "$CC_PLUGIN" list --cwd "$list_work" --claude "$FAKE_CLAUDE")"
list_archive="$(latest_plugin_archive "$list_work")"
assert_contains "$list_out" "claude-code-companion 0.4.0 enabled"
assert_contains "$list_out" "Authorization: Bearer REDACTED"
assert_not_contains "$list_out" "LISTSECRET"
assert_contains "$(cat "$list_archive/result.txt")" "Authorization: Bearer REDACTED"
assert_contains "$(cat "$list_archive/stdout.txt")" "Authorization: Basic REDACTED"
assert_contains "$(cat "$list_archive/stdout.txt")" "x-api-key: REDACTED"
assert_contains "$(cat "$list_archive/stdout.txt")" "http_proxy=REDACTED"
assert_not_contains "$(cat "$list_archive/stdout.txt")" "BASICLIST"
assert_not_contains "$(cat "$list_archive/stdout.txt")" "HEADERLIST"
assert_not_contains "$(cat "$list_archive/stdout.txt")" "user:pass"
assert_json_file "$list_archive/metadata.json"
assert_not_contains "$(cat "$list_args")" "update"
assert_not_contains "$(cat "$list_args")" "marketplace"

versions_work="$(new_workdir versions)"
versions_args="$TMP_ROOT/versions.args"
versions_out="$(FAKE_ARGS_LOG="$versions_args" "$CC_PLUGIN" versions --cwd "$versions_work" --claude "$FAKE_CLAUDE")"
versions_archive="$(latest_plugin_archive "$versions_work")"
assert_contains "$versions_out" "latest=0.4.1"
assert_contains "$versions_out" "sk-ant-REDACTED"
assert_not_contains "$versions_out" "versionsecret"
assert_json_file "$versions_archive/metadata.json"
assert_not_contains "$(cat "$versions_args")" "update"
assert_not_contains "$(cat "$versions_args")" "marketplace"

versions_fallback_work="$(new_workdir versions-fallback)"
versions_fallback_args="$TMP_ROOT/versions-fallback.args"
versions_fallback_out="$(FAKE_ARGS_LOG="$versions_fallback_args" FAKE_VERSIONS_UNAVAILABLE=1 "$CC_PLUGIN" versions --cwd "$versions_fallback_work" --claude "$FAKE_CLAUDE")"
assert_contains "$versions_fallback_out" "versions_command=unavailable"
assert_contains "$versions_fallback_out" "fell back to read-only plugin list"
assert_contains "$versions_fallback_out" "claude-code-companion 0.4.0 enabled"
assert_not_contains "$(cat "$versions_fallback_args")" "update"
assert_not_contains "$(cat "$versions_fallback_args")" "marketplace"

plan_work="$(new_workdir plan)"
plan_args="$TMP_ROOT/plan.args"
plan_out="$(FAKE_ARGS_LOG="$plan_args" "$CC_PLUGIN" plan-update --cwd "$plan_work" --claude "$FAKE_CLAUDE" --plugin siyuan-mcp --plugin zotero-mcp)"
plan_archive="$(latest_plugin_archive "$plan_work")"
assert_contains "$plan_out" "dry_run=yes"
assert_contains "$plan_out" "would_run=claude plugin marketplace update"
assert_contains "$plan_out" "would_run=claude plugin update siyuan-mcp"
assert_contains "$plan_out" "read-only"
assert_not_contains "$(cat "$plan_args")" "update"
assert_not_contains "$(cat "$plan_args")" "marketplace"
assert_json_file "$plan_archive/metadata.json"
assert_contains "$(cat "$plan_archive/metadata.json")" '"plugins": ["siyuan-mcp","zotero-mcp"]'

if FAKE_ARGS_LOG="$TMP_ROOT/plan-empty.args" "$CC_PLUGIN" plan-update --cwd "$plan_work" --claude "$FAKE_CLAUDE" >/dev/null 2>&1; then
  fail "plan-update without --plugin should fail"
fi
if FAKE_ARGS_LOG="$TMP_ROOT/plan-bad.args" "$CC_PLUGIN" plan-update --cwd "$plan_work" --claude "$FAKE_CLAUDE" --plugin '../evil' >/dev/null 2>&1; then
  fail "unsafe plugin name should fail"
fi
if FAKE_ARGS_LOG="$TMP_ROOT/update-command.args" "$CC_PLUGIN" update --cwd "$plan_work" --claude "$FAKE_CLAUDE" --plugin siyuan-mcp >/dev/null 2>&1; then
  fail "unknown update command should fail"
fi
if [ -f "$TMP_ROOT/update-command.args" ]; then
  fail "unknown update command should not invoke Claude"
fi
if FAKE_ARGS_LOG="$TMP_ROOT/list-extra.args" "$CC_PLUGIN" list --cwd "$plan_work" --claude "$FAKE_CLAUDE" update >/dev/null 2>&1; then
  fail "extra positional arg should fail"
fi
if [ -f "$TMP_ROOT/list-extra.args" ]; then
  fail "extra positional arg should not invoke Claude"
fi

state_work="$(new_workdir state-root)"
state_parent="$state_work/custom-state"
state_args="$TMP_ROOT/state.args"
state_out="$(FAKE_ARGS_LOG="$state_args" "$CC_PLUGIN" list --cwd "$state_work" --state-root "$state_parent" --claude "$FAKE_CLAUDE")"
assert_contains "$state_out" "claude-code-companion"
[ ! -d "$state_work/.cc-watch" ] || fail "custom state root should not write default .cc-watch"
[ -d "$state_parent/.cc-watch/plugin-admin" ] || fail "custom state root missing plugin-admin archive"
[ ! -f "$state_parent/.gitignore" ] || fail "custom state root wrote gitignore to parent dir"

external_work="$(new_workdir external)"
external_parent="$TMP_ROOT/external-state"
if FAKE_ARGS_LOG="$TMP_ROOT/external-denied.args" "$CC_PLUGIN" list --cwd "$external_work" --state-root "$external_parent" --claude "$FAKE_CLAUDE" >/dev/null 2>&1; then
  fail "external state root without allow flag should fail"
fi
[ ! -e "$external_parent" ] || fail "denied external state root should not be created"
external_out="$(FAKE_ARGS_LOG="$TMP_ROOT/external-allowed.args" "$CC_PLUGIN" list --cwd "$external_work" --state-root "$external_parent" --allow-external-state-root --claude "$FAKE_CLAUDE")"
assert_contains "$external_out" "claude-code-companion"
external_archive="$(latest_plugin_archive "$external_parent")"
assert_contains "$(cat "$external_archive/metadata.json")" '"external_state": "1"'

printf 'test_cc_plugin ok\n'
