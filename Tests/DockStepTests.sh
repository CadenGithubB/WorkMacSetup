#!/bin/bash
# Exercises only the guided Dock functions, with all UI/system calls stubbed.
# Never sources or runs the production setup entry point.
set -eu

TEST_DIR="$(cd "$(dirname "$0")" && /bin/pwd)"
SETUP_SCRIPT="${TEST_DIR}/../post-enrollment.sh"
FIXTURE_DIR="$(/usr/bin/mktemp -d -t workmacsetup-dock-test)"
trap '/bin/rm -rf -- "$FIXTURE_DIR"' EXIT

# Function bodies have their closing brace at column zero. Extract only the
# four pure/guided functions needed here; none of the setup main runs.
eval "$(/usr/bin/awk '
  /^(url_encode|list_step_apps|guided_settings_step|show_dock_apps)\(\) \{/ { copying = 1 }
  copying { print }
  copying && /^\}$/ { copying = 0 }
' "$SETUP_SCRIPT")"

assert_equal() {
  [[ "$1" == "$2" ]] || {
    /usr/bin/printf 'FAIL: %s\n  expected: %s\n  actual: %s\n' "$3" "$2" "$1" >&2
    exit 1
  }
}

log() { /usr/bin/printf '%s\n' "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); /usr/bin/printf '%s\n' "$*"; }
fail() { /usr/bin/printf 'Unexpected failure: %s\n' "$*" >&2; exit 1; }
focus_terminal() { fail 'Dock step should not focus Terminal as a final Settings step.'; }

# No installed applications or real settings are touched. Even cleanup within
# the guided function is intercepted; the test trap removes its own fixture.
run_as_user() {
  case "$1" in
    /usr/bin/mktemp)
      /usr/bin/printf '%s\n' "${FIXTURE_DIR}/workmacsetup-step.test"
      ;;
    /bin/rm)
      assert_equal "${4:-}" "${FIXTURE_DIR}/workmacsetup-step.test" 'temporary cleanup target'
      ;;
    *) fail "Unexpected system command: $*" ;;
  esac
}

drag_palette() {
  PALETTE_REQUESTS[${#PALETTE_REQUESTS[@]}]="$1"
  if [[ "$1" == workmacsetup://drag-palette\?* ]]; then
    [[ "$PALETTE_AVAILABLE" -eq 1 ]] || return 1
    # Simulate Done. The real palette creates this same empty marker.
    /usr/bin/printf '%s' "${HELPER_RESULT:-}" > "${FIXTURE_DIR}/workmacsetup-step.test/done"
  fi
}

reset_fixture() {
  WARNINGS=0
  SHOW_DOCK_APPS=1
  PALETTE_AVAILABLE=1
  PALETTE_REQUESTS=()
  PALETTE_URL=""
  LISTED_APPS=0
  STEP_DONE_DIR=""
  STEP_READER_PID=""
  HELPER_RESULT=""
  /bin/mkdir -p "${FIXTURE_DIR}/workmacsetup-step.test"
  /bin/rm -f -- "${FIXTURE_DIR}/workmacsetup-step.test/done"
}

/bin/mkdir -p "${FIXTURE_DIR}/Example & Co.app" "${FIXTURE_DIR}/Not an app"

reset_fixture
SHOW_DOCK_APPS=0
DOCK_APPS=("${FIXTURE_DIR}/Example & Co.app")
show_dock_apps < /dev/null > "${FIXTURE_DIR}/output"
assert_equal "${#PALETTE_REQUESTS[@]}" 0 'disabled action does not show a palette'

reset_fixture
DOCK_APPS=("${FIXTURE_DIR}/Example & Co.app" "${FIXTURE_DIR}/Missing.app" "${FIXTURE_DIR}/Not an app")
show_dock_apps < /dev/null > "${FIXTURE_DIR}/output"
assert_equal "$LISTED_APPS" 1 'only an existing application is listed'
assert_equal "$WARNINGS" 2 'invalid selections produce warnings'
assert_equal "${#PALETTE_REQUESTS[@]}" 2 'palette shows and closes after Done'
assert_equal "${PALETTE_REQUESTS[0]}" \
  "workmacsetup://drag-palette?step=dock&app=$(url_encode "${FIXTURE_DIR}/Example & Co.app")&done=$(url_encode "${FIXTURE_DIR}/workmacsetup-step.test/done")" \
  'Dock palette URL keeps encoded paths and includes the completion marker'
assert_equal "${PALETTE_REQUESTS[1]}" 'workmacsetup://drag-palette/close' 'closing the Dock palette does not quit System Settings'
assert_equal "$STEP_DONE_DIR" '' 'completion clears the active step folder'

reset_fixture
DOCK_APPS=()
show_dock_apps < /dev/null > "${FIXTURE_DIR}/output"
assert_equal "$LISTED_APPS" 0 'empty selection is supported'
assert_equal "${#PALETTE_REQUESTS[@]}" 2 'empty selection still permits Done'

reset_fixture
PALETTE_AVAILABLE=0
DOCK_APPS=("${FIXTURE_DIR}/Example & Co.app")
show_dock_apps < /dev/null > "${FIXTURE_DIR}/output"
assert_equal "$WARNINGS" 1 'unavailable palette is reported'
assert_equal "${#PALETTE_REQUESTS[@]}" 1 'unavailable palette does not wait for Done'
OUTPUT="$(< "${FIXTURE_DIR}/output")"
[[ "$OUTPUT" == *'In Finder, locate the applications listed above and drag each one onto the apps side of the Dock'* ]] || fail 'Missing Finder fallback instructions.'

reset_fixture
DOCK_APPS=()
HELPER_RESULT='error: The read-only Dock window could not complete (exit 3).'
REPORTED_FAILURE=""
fail() { REPORTED_FAILURE="$*"; }
show_dock_apps < /dev/null > "${FIXTURE_DIR}/output"
assert_equal "$REPORTED_FAILURE" 'The read-only Dock window could not complete (exit 3).' 'helper failures must not silently complete successfully'

/usr/bin/printf 'PASS: Dock disabled, selected/invalid apps, Done handshake, empty selection, Finder fallback, and helper errors.\n'
