#!/bin/bash

# Setup for a new work Mac: Chrome profiles, the Windows App setting, and
# guided Dock, Login Items, and Screen Recording steps. No administrator password needed.
# Compatible with the Bash 3.2 version included with macOS.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd)"
CONFIG_FILE="${SCRIPT_DIR}/setup.conf"
SKIP_PRIVACY=0
ENTER_CLIENTS=0
FAILURES=0
WARNINGS=0
FIRST_STEP_FAILURE=""
FIRST_STEP_WARNING=""
TEMP_CLIENTS_FILE=""

usage() {
  /usr/bin/printf '%s\n' \
    'Usage: post-enrollment.sh [options]' \
    '' \
    'Options:' \
    '  --config PATH    Use a different configuration file.' \
    '  --enter-clients  Prompt for client names instead of reading clients.tsv.' \
    '  --skip-privacy   Do not open Screen & System Audio Recording settings.' \
    '  -h, --help       Show this help.'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { /usr/bin/printf 'Missing value for --config.\n' >&2; exit 2; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --enter-clients)
      ENTER_CLIENTS=1
      shift
      ;;
    --skip-privacy)
      SKIP_PRIVACY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      /usr/bin/printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
  /usr/bin/printf 'This script only supports macOS.\n' >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  /usr/bin/printf 'Configuration not found: %s\nCopy setup.conf.example to setup.conf and edit it first.\n' "$CONFIG_FILE" >&2
  exit 1
fi

# The config is deliberately shell syntax so Bash 3.2 can read arrays without extra tools.
# Only source a file you control.
# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${CLIENTS_FILE:=clients.tsv}"
: "${SET_WINDOWS_CREDSSP:=1}"
# Accept the older flag without retaining the old isolated-launcher behavior.
: "${CREATE_CHROME_PROFILES:=${CREATE_CHROME_LAUNCHERS:-1}}"
: "${OPEN_SCREEN_RECORDING_SETTINGS:=0}"
: "${OPEN_LOGIN_ITEMS_SETTINGS:=0}"
: "${SHOW_DOCK_APPS:=0}"
: "${CHROME_APP_PATH:=/Applications/Google Chrome.app}"
# Set by the app so its window can show each step's state; unused otherwise.
: "${STATUS_FILE:=}"

if [[ "$CLIENTS_FILE" != /* ]]; then
  CLIENTS_FILE="${SCRIPT_DIR}/${CLIENTS_FILE}"
fi

if ! declare -p LOGIN_ITEM_APPS >/dev/null 2>&1; then
  LOGIN_ITEM_APPS=()
fi
if ! declare -p DOCK_APPS >/dev/null 2>&1; then
  DOCK_APPS=()
fi
if ! declare -p SCREEN_RECORDING_APPS >/dev/null 2>&1; then
  SCREEN_RECORDING_APPS=()
fi
PALETTE_URL=""
LISTED_APPS=0
STEP_DONE_DIR=""
STEP_READER_PID=""
WINDOWS_APP_COMMAND="defaults write com.microsoft.rdc.macos ClientSettings.EnforceCredSSPSupport 0"

timestamp() {
  /bin/date '+%Y-%m-%d %H:%M:%S'
}

log() {
  /usr/bin/printf '[%s] %s\n' "$(timestamp)" "$*"
}

warn() {
  /usr/bin/printf '[%s] WARNING: %s\n' "$(timestamp)" "$*" >&2
  WARNINGS=$((WARNINGS + 1))
  [[ -n "$FIRST_STEP_WARNING" ]] || FIRST_STEP_WARNING="$*"
}

fail() {
  /usr/bin/printf '[%s] ERROR: %s\n' "$(timestamp)" "$*" >&2
  FAILURES=$((FAILURES + 1))
  [[ -n "$FIRST_STEP_FAILURE" ]] || FIRST_STEP_FAILURE="$*"
}

CONSOLE_USER="$(/usr/bin/stat -f '%Su' /dev/console)"
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" || "$CONSOLE_USER" == "_mbsetupuser" ]]; then
  /usr/bin/printf 'No normal user is logged in at the console. Finish Setup Assistant and log in before running this script.\n' >&2
  exit 1
fi

CONSOLE_UID="$(/usr/bin/id -u "$CONSOLE_USER")"
USER_HOME="$(/usr/bin/dscl . -read "/Users/${CONSOLE_USER}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
if [[ -z "$USER_HOME" ]]; then
  USER_HOME="$(/usr/bin/dscacheutil -q user -a name "$CONSOLE_USER" 2>/dev/null | /usr/bin/awk '$1 == "dir:" { sub(/^dir:[[:space:]]*/, ""); print; exit }')"
fi
if [[ -z "$USER_HOME" && -d "/Users/${CONSOLE_USER}" ]]; then
  USER_HOME="/Users/${CONSOLE_USER}"
fi
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
  /usr/bin/printf 'Could not determine a valid home directory for %s.\n' "$CONSOLE_USER" >&2
  exit 1
fi

run_as_user() {
  if [[ "$(/usr/bin/id -u)" -eq "$CONSOLE_UID" ]]; then
    "$@"
  elif [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
    /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" -- "$@"
  else
    /usr/bin/printf 'Administrator access is required to run a command as %s.\n' "$CONSOLE_USER" >&2
    return 1
  fi
}

# Percent-encode a string for use in a URL query value (Bash 3.2, byte-wise).
url_encode() {
  (
    LC_ALL=C
    local string="$1" i c
    for ((i = 0; i < ${#string}; i++)); do
      c="${string:i:1}"
      case "$c" in
        [A-Za-z0-9./_-]) /usr/bin/printf '%s' "$c" ;;
        *) /usr/bin/printf '%%%02X' "'$c" ;;
      esac
    done
  )
}

# The Work Mac Setup app that contains this script, when it is run from the
# packaged app bundle or from the repository with a built dist/ app.
setup_app_bundle() {
  if [[ "$SCRIPT_DIR" == *.app/Contents/Resources ]]; then
    /usr/bin/printf '%s' "${SCRIPT_DIR%/Contents/Resources}"
  elif [[ -d "${SCRIPT_DIR}/dist/Work Mac Setup.app" ]]; then
    /usr/bin/printf '%s' "${SCRIPT_DIR}/dist/Work Mac Setup.app"
  fi
}

# Ask the app to show or hide the floating drag palette for a guided step.
# -g keeps Terminal and System Settings in front. The URL only names the apps
# to display; the app never launches them or changes any setting.
drag_palette() {
  local url="$1"
  local app_bundle
  app_bundle="$(setup_app_bundle)"
  if [[ -n "$app_bundle" ]]; then
    run_as_user /usr/bin/open -g -a "$app_bundle" "$url"
  else
    run_as_user /usr/bin/open -g "$url"
  fi
}

# Print a numbered list of the given .app paths and build the palette URL for
# a step. Paths that are not existing .app directories are skipped with a
# warning; nothing at these paths is executed. Sets PALETTE_URL and LISTED_APPS.
list_step_apps() {
  local step="$1"
  shift
  local app_path app_name
  LISTED_APPS=0
  PALETTE_URL="workmacsetup://drag-palette?step=${step}"
  for app_path in "$@"; do
    if [[ "$app_path" != *.app || ! -d "$app_path" ]]; then
      warn "Skipping an entry that is not an installed application: ${app_path}"
      continue
    fi
    app_name="$(/usr/bin/basename "$app_path" .app)"
    LISTED_APPS=$((LISTED_APPS + 1))
    /usr/bin/printf '  %2d. %s\n      %s\n' "$LISTED_APPS" "$app_name" "$app_path"
    PALETTE_URL="${PALETTE_URL}&app=$(url_encode "$app_path")"
  done
  if [[ "$LISTED_APPS" -eq 0 ]]; then
    /usr/bin/printf '  (no applications were selected)\n'
  fi
}

# Bring the terminal that is running this script back to the front.
focus_terminal() {
  local bundle=""
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) bundle="com.apple.Terminal" ;;
    iTerm.app) bundle="com.googlecode.iterm2" ;;
    *) return 0 ;;
  esac
  run_as_user /usr/bin/open -b "$bundle" >/dev/null 2>&1 || true
}

# Open a System Settings page, show the drag palette, and wait for Done.
#   $1 settings URL   $2 page name   $3 1 if this is the last guided step
#   $4 fallback instruction (no palette)
#   remaining arguments: instruction lines shown when the palette is available
# The user makes the change in System Settings; the script only guides. After
# the last step, System Settings is closed and the terminal comes forward.
guided_settings_step() {
  local settings_url="$1" page="$2" last_step="$3" fallback="$4"
  shift 4
  local done_dir="" done_file="" palette_shown=0 reader_pid=""
  local close_url="workmacsetup://drag-palette/close"
  if [[ "$last_step" -eq 1 ]]; then
    PALETTE_URL="${PALETTE_URL}&last=1"
    close_url="${close_url}?settings=quit"
  fi

  # Done in the palette creates this empty marker file; the app only writes a
  # file by that name inside a workmacsetup-step.* temporary folder.
  done_dir="$(run_as_user /usr/bin/mktemp -d -t workmacsetup-step 2>/dev/null)" || done_dir=""
  if [[ -n "$done_dir" ]]; then
    STEP_DONE_DIR="$done_dir"
    done_file="${done_dir}/done"
    PALETTE_URL="${PALETTE_URL}&done=$(url_encode "$done_file")"
  fi

  # Steps finished outside System Settings pass an empty settings URL.
  if [[ -n "$settings_url" ]]; then
    log "Opening System Settings > ${page}."
    if ! run_as_user /usr/bin/open "$settings_url"; then
      warn "The direct System Settings URL failed; opening System Settings instead."
      if ! run_as_user /usr/bin/open -a "System Settings"; then
        fail "Could not open System Settings."
        return
      fi
    fi
  fi

  if drag_palette "$PALETTE_URL" 2>/dev/null; then
    palette_shown=1
    /usr/bin/printf '%s\n' '' "$@" 'Click Done in that window when you are finished; setup continues on its own.'
  else
    warn "The Work Mac Setup app is not available to show the drag palette."
    /usr/bin/printf '%s\n' '' "$fallback"
  fi

  if [[ -t 0 ]]; then
    /usr/bin/printf '%s\n' '(You can also press Return here to continue.)'
    if [[ -n "$done_file" ]]; then
      # Bash 3.2 cannot tell a timed-out read from end of input, so a helper
      # waits for Return and creates the same marker file that Done creates.
      # It must read /dev/tty: a background command's stdin is /dev/null.
      ( IFS= read -r _ < /dev/tty && /usr/bin/touch "$done_file" ) 2>/dev/null &
      reader_pid=$!
      STEP_READER_PID="$reader_pid"
      while [[ ! -e "$done_file" ]]; do
        /bin/sleep 0.5
      done
      # SIGKILL: Bash defers SIGTERM while blocked in read, and a surviving
      # helper would swallow the next Return.
      { kill -KILL "$reader_pid" && wait "$reader_pid"; } >/dev/null 2>&1 || true
      STEP_READER_PID=""
    else
      IFS= read -r _
    fi
    drag_palette "$close_url" >/dev/null 2>&1 || true
    log "Continuing after ${page}."
    if [[ "$last_step" -eq 1 ]]; then
      focus_terminal
    fi
  elif [[ "$palette_shown" -eq 1 && -n "$done_file" ]]; then
    log "Waiting for Done in the ${page} window."
    while [[ ! -e "$done_file" ]]; do /bin/sleep 1; done
    drag_palette "$close_url" >/dev/null 2>&1 || true
    log "Continuing after ${page}."
  else
    log "The setup window is not available; finish the ${page} step yourself. Continuing."
  fi

  if [[ -n "$done_file" && -s "$done_file" ]]; then
    local completion_message
    completion_message="$(< "$done_file")"
    if [[ "$completion_message" == 'error: '* ]]; then
      fail "${completion_message#error: }"
    fi
  fi

  if [[ -n "$done_dir" ]]; then
    run_as_user /bin/rm -rf -- "$done_dir" >/dev/null 2>&1 || true
    STEP_DONE_DIR=""
  fi
}

write_user_file() {
  local destination="$1"
  local contents="$2"
  run_as_user /bin/bash -c 'umask 077; /usr/bin/printf "%s" "$2" > "$1"' _ "$destination" "$contents"
}

color_to_rgb() {
  local color
  local hex
  color="$(/usr/bin/printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]')"

  case "$color" in
    blue)   /usr/bin/printf '66,133,244' ;;
    red)    /usr/bin/printf '219,68,55' ;;
    green)  /usr/bin/printf '15,157,88' ;;
    orange) /usr/bin/printf '244,160,0' ;;
    yellow) /usr/bin/printf '251,188,4' ;;
    purple) /usr/bin/printf '171,71,188' ;;
    pink)   /usr/bin/printf '233,30,99' ;;
    teal)   /usr/bin/printf '0,150,136' ;;
    gray|grey) /usr/bin/printf '96,125,139' ;;
    \#[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      hex="${color#\#}"
      /usr/bin/printf '%d,%d,%d' \
        "$((16#${hex:0:2}))" \
        "$((16#${hex:2:2}))" \
        "$((16#${hex:4:2}))"
      ;;
    *)
      return 1
      ;;
  esac
}

cleanup() {
  if [[ -n "$TEMP_CLIENTS_FILE" && -f "$TEMP_CLIENTS_FILE" ]]; then
    /bin/rm -f -- "$TEMP_CLIENTS_FILE"
  fi
  if [[ -n "$STEP_DONE_DIR" && -d "$STEP_DONE_DIR" ]]; then
    /bin/rm -rf -- "$STEP_DONE_DIR"
  fi
  if [[ -n "$STEP_READER_PID" ]]; then
    kill -KILL "$STEP_READER_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT
# Stop on hangup, interrupt, or termination; the EXIT trap still cleans up.
trap 'exit 129' HUP
trap 'exit 130' INT
trap '/usr/bin/printf "\nSetup was stopped.\n"; exit 143' TERM

collect_interactive_clients() {
  local entry label start_url color_spec color_suffix
  local count=0

  if [[ "$ENTER_CLIENTS" -ne 1 ]]; then
    return
  fi

  if [[ ! -t 0 ]]; then
    /usr/bin/printf 'Interactive client entry requires a Terminal window.\n' >&2
    exit 1
  fi

  TEMP_CLIENTS_FILE="$(/usr/bin/mktemp -t workmacsetup-clients)" || {
    /usr/bin/printf 'Could not create a temporary client list.\n' >&2
    exit 1
  }
  /bin/chmod 600 "$TEMP_CLIENTS_FILE"
  # The profile helper always runs as the console user, including when the
  # standalone script is started with sudo. Only change this new temporary file.
  if [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
    /usr/sbin/chown "$CONSOLE_UID" "$TEMP_CLIENTS_FILE" || {
      /usr/bin/printf 'Could not prepare the temporary client list for the signed-in user.\n' >&2
      exit 1
    }
  fi
  CLIENTS_FILE="$TEMP_CLIENTS_FILE"

  /usr/bin/printf '%s\n' \
    '' \
    'Paste one client name per line.' \
    'Press Return on an empty line after the final client.' \
    'Optional color flags: -blue, -red, -green, -orange, -yellow, -purple, -pink, -teal, or -gray.' \
    'Example: Example Client -blue' \
    'Optional: place a tab and https:// URL after the name/color to set a start page.' \
    'No passwords, tokens, or recovery codes.' \
    ''

  while true; do
    IFS= read -r entry || break
    entry="${entry%$'\r'}"
    [[ -z "$entry" ]] && break

    if [[ "$entry" == *$'\t'* ]]; then
      label="${entry%%$'\t'*}"
      start_url="${entry#*$'\t'}"
    else
      label="$entry"
      start_url="about:blank"
    fi

    color_spec=""
    if [[ "$label" =~ [[:space:]]-([A-Za-z]+|#[0-9A-Fa-f]{6})$ ]]; then
      color_suffix="${BASH_REMATCH[0]}"
      color_spec="${BASH_REMATCH[1]}"
      label="${label:0:$((${#label} - ${#color_suffix}))}"
      if ! color_to_rgb "$color_spec" >/dev/null; then
        warn "Unknown color '-${color_spec}'. Skipped that line; use a listed color or -#RRGGBB."
        continue
      fi
    fi

    if [[ -z "$label" ]]; then
      warn "Skipped an entry with no client name."
      continue
    fi

    /usr/bin/printf '%s\t%s\t%s\n' "$label" "$start_url" "$color_spec" >> "$TEMP_CLIENTS_FILE"
    count=$((count + 1))
  done

  if [[ "$count" -eq 0 ]]; then
    /usr/bin/printf 'No client names were entered; no changes were made.\n' >&2
    exit 1
  fi

  log "Accepted ${count} client name(s); the temporary input list will be deleted on exit."
}

configure_windows_app() {
  if [[ "$SET_WINDOWS_CREDSSP" -ne 1 ]]; then
    log "Skipping the Windows App CredSSP preference."
    return
  fi

  # Windows App keeps its settings in its own sandbox, and macOS asks before
  # another app writes there. From the app, show the command for the user to
  # paste into Terminal, so Work Mac Setup never needs that access. From
  # Terminal, the script is already running there, so set it directly.
  if [[ ! -t 0 ]]; then
    log "Windows App setting to run in Terminal:"
    /usr/bin/printf '  %s\n' "$WINDOWS_APP_COMMAND"
    PALETTE_URL="workmacsetup://drag-palette?step=windows-app"
    guided_settings_step "" "Windows App setting" 0 \
      'Open Terminal, paste the command above, and press Return.' \
      'A small "Windows App setting" window shows the command with a Copy button.' \
      'Paste it into Terminal and press Return. If Terminal asks to access data from other apps, click Allow.'
    return
  fi

  log "Setting the Windows App CredSSP preference for ${CONSOLE_USER}."
  # This is intentionally the exact preference domain, key, and value requested.
  if ! run_as_user /usr/bin/defaults write com.microsoft.rdc.macos ClientSettings.EnforceCredSSPSupport 0; then
    fail "Could not set ClientSettings.EnforceCredSSPSupport."
    return
  fi

  local value
  value="$(run_as_user /usr/bin/defaults read com.microsoft.rdc.macos ClientSettings.EnforceCredSSPSupport 2>/dev/null || true)"
  if [[ "$value" != "0" ]]; then
    fail "CredSSP preference verification returned '${value}' instead of 0."
  else
    log "Verified ClientSettings.EnforceCredSSPSupport = 0."
  fi
}

create_chrome_profiles() {
  local helper="${SCRIPT_DIR}/chrome-profile-helper"
  local helper_args
  if [[ "$CREATE_CHROME_PROFILES" -ne 1 ]]; then
    log "Skipping Chrome profile creation."
    return
  fi

  if [[ ! -x "$helper" ]]; then
    helper="${SCRIPT_DIR}/.build/chrome-profile-helper"
  fi
  if [[ ! -x "$helper" ]]; then
    fail "Chrome profile helper is missing. Run ./build-app.sh, or use the complete Work Mac Setup.app."
    return
  fi
  if [[ ! -f "$CLIENTS_FILE" ]]; then
    fail "Client list not found: ${CLIENTS_FILE}"
    return
  fi
  if [[ ! -d "$CHROME_APP_PATH" ]]; then
    fail "Google Chrome is not installed at ${CHROME_APP_PATH}. Install Google Chrome Stable, then run setup again."
    return
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CHROME_APP_PATH/Contents/Info.plist" 2>/dev/null)" != "com.google.Chrome" ]]; then
    fail "Profile creation supports Google Chrome Stable, not another browser or Chrome channel."
    return
  fi

  helper_args=(--clients-file "$CLIENTS_FILE")

  log "Preparing local Chrome profiles for the profile picker. No account is connected and Sync is not enabled."
  # The helper always runs as the signed-in user so it uses their Chrome data.
  if [[ "$(/usr/bin/id -u)" -eq "$CONSOLE_UID" ]]; then
    "$helper" "${helper_args[@]}"
  elif [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
    /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" -- "$helper" "${helper_args[@]}"
  else
    fail "Run setup from the logged-in user's account."
    return
  fi
  if [[ "$?" -ne 0 ]]; then
    fail "Chrome profile creation did not complete. Review the message and any recovery journal above before retrying."
  fi
}

show_dock_apps() {
  if [[ "$SHOW_DOCK_APPS" -ne 1 ]]; then
    log "Skipping Dock apps."
    return
  fi

  log "Applications to add to the Dock:"
  if [[ ${#DOCK_APPS[@]} -gt 0 ]]; then
    list_step_apps dock "${DOCK_APPS[@]}"
  else
    list_step_apps dock
  fi

  guided_settings_step "" "Dock apps" 0 \
    'In Finder, locate the applications listed above and drag each one onto the apps side of the Dock, before the separator beside folders and Trash.' \
    'A small "Drag into the Dock" window lists the applications above.' \
    'Drag each icon from that window onto the apps side of the Dock, before the separator beside folders and Trash.' \
    'Place each icon where you want it. If the Dock is hidden, move the pointer to its screen edge to reveal it.'
}

open_login_items_settings() {
  if [[ "$OPEN_LOGIN_ITEMS_SETTINGS" -ne 1 ]]; then
    log "Skipping Login Items settings."
    return
  fi

  log "Login items to add under Open at Login:"
  if [[ ${#LOGIN_ITEM_APPS[@]} -gt 0 ]]; then
    list_step_apps login-items "${LOGIN_ITEM_APPS[@]}"
  else
    list_step_apps login-items
  fi

  local last_step=1
  if [[ "$SKIP_PRIVACY" -ne 1 && "$OPEN_SCREEN_RECORDING_SETTINGS" -eq 1 ]]; then
    last_step=0
  fi
  guided_settings_step \
    "x-apple.systempreferences:com.apple.LoginItems-Settings.extension" \
    "General > Login Items" \
    "$last_step" \
    'In System Settings, click "+" under "Open at Login" and add the applications listed above.' \
    'A small "Drag into Open at Login" window lists the applications above.' \
    'Drag each one from that window into the "Open at Login" list in System Settings.' \
    'If dragging does not work, click "+" under "Open at Login" and choose the application instead.'
}

open_privacy_settings() {
  if [[ "$SKIP_PRIVACY" -eq 1 || "$OPEN_SCREEN_RECORDING_SETTINGS" -ne 1 ]]; then
    log "Skipping Screen & System Audio Recording settings."
    return
  fi

  log "Applications to allow under Screen & System Audio Recording:"
  if [[ ${#SCREEN_RECORDING_APPS[@]} -gt 0 ]]; then
    list_step_apps screen-recording "${SCREEN_RECORDING_APPS[@]}"
  else
    list_step_apps screen-recording
  fi

  guided_settings_step \
    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" \
    "Privacy & Security > Screen & System Audio Recording" \
    1 \
    'In System Settings, click "+" under "Screen & System Audio Recording", add the applications listed above, and turn on their switches.' \
    'A small "Allow Screen Recording" window lists the applications above.' \
    'Drag each one from that window into the "Screen & System Audio Recording" list, then turn on its switch.' \
    'If dragging does not work, click "+" and choose the application instead.' \
    'macOS may ask you to quit and reopen an application before the permission applies.'
}

# Lines are step<TAB>state<TAB>message, appended as each step runs.
record_step() {
  local message="${3:-}"
  [[ -n "$STATUS_FILE" ]] || return 0
  message="${message//$'\t'/ }"
  /usr/bin/printf '%s\t%s\t%s\n' "$1" "$2" "$message" >> "$STATUS_FILE"
}

# Runs one setup step and records whether it completed, warned, or failed.
# A failed step does not stop the steps after it.
run_step() {
  local id="$1" step_function="$2"
  local failures_before="$FAILURES" warnings_before="$WARNINGS"
  FIRST_STEP_FAILURE=""
  FIRST_STEP_WARNING=""
  record_step "$id" running
  "$step_function"
  if [[ "$FAILURES" -gt "$failures_before" ]]; then
    record_step "$id" failed "$FIRST_STEP_FAILURE"
  elif [[ "$WARNINGS" -gt "$warnings_before" ]]; then
    record_step "$id" warning "$FIRST_STEP_WARNING"
  else
    record_step "$id" done
  fi
}

log "Starting setup for ${CONSOLE_USER}."
collect_interactive_clients
run_step chrome-profiles create_chrome_profiles
run_step dock show_dock_apps
run_step login-items open_login_items_settings
run_step screen-recording open_privacy_settings
run_step windows-app configure_windows_app

if [[ "$FAILURES" -gt 0 ]]; then
  /usr/bin/printf '\nSetup finished with %d error(s). Review the messages above.\n' "$FAILURES" >&2
  exit 1
fi

/usr/bin/printf '\nSetup completed successfully.\n'
if [[ "$CREATE_CHROME_PROFILES" -eq 1 ]]; then
  /usr/bin/printf 'Open Chrome and choose a client in the profile picker. New profiles are local and signed out.\n'
fi
/usr/bin/printf 'The app does not connect a Google account or enable Chrome Sync.\n'
