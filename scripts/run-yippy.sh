#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly PROJECT_DIR="${SCRIPT_DIR:h}"
readonly PROJECT_FILE="${PROJECT_DIR}/Maccy.xcodeproj"
readonly SCHEME="Maccy"

# NOTE: BUILD_ROOT used to live under $TMPDIR, which macOS treats as purgeable
# (cleared on reboot, by cache cleaners, `rm -rf $TMPDIR`, etc.) — and the final
# Yippy.app lived inside DerivedData, so any cache clean wiped the app itself.
# Keep everything under the (gitignored) project-local ./build directory so the
# shipped .app survives cache clears. Only DerivedData is safe to delete.
readonly BUILD_ROOT="${PROJECT_DIR}/build"
readonly DERIVED_DATA="${BUILD_ROOT}/DerivedData"
readonly SOURCE_PACKAGES="${BUILD_ROOT}/SourcePackages"
readonly LOCAL_DIST_DIR="${BUILD_ROOT}/Yippy"
readonly APPLICATIONS_APP_PATH="/Applications/Yippy.app"
readonly BUILD_LOG="${BUILD_ROOT}/xcodebuild.log"
readonly SCRIPT_NAME="${0:t}"

# Defaults (overridable via flags or interactive prompts below).
CONFIGURATION="Debug"
DEST="local"
LAUNCH=1
ASSUME_YES=0

# ---- Formatting -------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  readonly C_BOLD=$'\e[1m'
  readonly C_DIM=$'\e[2m'
  readonly C_RESET=$'\e[0m'
  readonly C_RED=$'\e[31m'
  readonly C_GREEN=$'\e[32m'
  readonly C_YELLOW=$'\e[33m'
  readonly C_CYAN=$'\e[36m'
else
  readonly C_BOLD="" C_DIM="" C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN=""
fi

step() {
  print -P "\n${C_BOLD}${C_CYAN}==>${C_RESET} ${C_BOLD}$1${C_RESET}"
}

info() {
  print "    $1"
}

ok() {
  print -P "${C_GREEN}✔${C_RESET} $1"
}

warn() {
  print -u2 -P "${C_YELLOW}⚠${C_RESET} $1"
}

fail() {
  print -u2 -P "${C_RED}✘ error:${C_RESET} $1"
  exit 1
}

elapsed_since() {
  local start="$1"
  print $(( $(date +%s) - start ))
}

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Build Yippy and stage it somewhere runnable.

Options:
  --config <Debug|Release>   Build configuration (default: ${CONFIGURATION})
  --dest <local|applications|PATH>
                             Where to put Yippy.app (default: ${DEST})
                               local         -> ./build/Yippy/Yippy.app
                               applications  -> /Applications/Yippy.app
                               PATH          -> custom dir (Yippy.app is created inside),
                                                or a full path ending in .app
  --launch / --no-launch     Open the app after building (default: launch)
  -y, --yes                  Accept defaults, never prompt
  -h, --help                 Show this help

Without flags and with an interactive terminal, the script asks what you
want (config, destination, launch) before building.
EOF
}

# ---- Arg parsing ------------------------------------------------------

while (( $# > 0 )); do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || fail "--config needs a value (Debug|Release)"
      CONFIGURATION="$2"
      shift 2
      ;;
    --config=*)
      CONFIGURATION="${1#--config=}"
      shift
      ;;
    --dest)
      [[ $# -ge 2 ]] || fail "--dest needs a value (local|applications|PATH)"
      DEST="$2"
      shift 2
      ;;
    --dest=*)
      DEST="${1#--dest=}"
      shift
      ;;
    --launch)
      LAUNCH=1
      shift
      ;;
    --no-launch)
      LAUNCH=0
      shift
      ;;
    -y|--yes)
      ASSUME_YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1 (see --help)"
      ;;
  esac
done

case "${CONFIGURATION}" in
  Debug|Release) ;;
  *) fail "--config must be Debug or Release (got: ${CONFIGURATION})" ;;
esac

# ---- Interactive prompts ----------------------------------------------
#
# When run by a human with no explicit choices, ask what they want instead
# of silently doing the default. Flags and --yes skip the questions.

prompt_choice() {
  # $1 = prompt, $2 = default value, $3.. = options as "value|label"
  # (label optional, defaults to value). Shows a numbered menu, prints the
  # chosen value. Accepts the number, or the value/label (case-insensitive);
  # empty input picks the default.
  local prompt="$1" default="$2"
  shift 2
  local -a values labels
  local opt value label reply_ i
  for opt in "$@"; do
    value="${opt%%|*}"
    if [[ "${opt}" == *"|"* ]]; then label="${opt#*|}"; else label="${value}"; fi
    values+=("${value}")
    labels+=("${label}")
  done
  while true; do
    print -P "  ${C_BOLD}${prompt}${C_RESET}" > /dev/tty
    local i
    for (( i = 1; i <= ${#values}; i++ )); do
      if [[ "${values[$i]}" == "${default}" ]]; then
        print "    $i) ${labels[$i]} (default)" > /dev/tty
      else
        print "    $i) ${labels[$i]}" > /dev/tty
      fi
    done
    printf "  Enter a number [%s]: " "${default}" > /dev/tty
    read -r reply_ < /dev/tty || reply_=""
    reply_="${reply_:-$default}"
    if [[ "${reply_}" =~ '^[0-9]+$' ]] && (( reply_ >= 1 && reply_ <= ${#values} )); then
      print -r -- "${values[$reply_]}"
      return
    fi
    for (( i = 1; i <= ${#values}; i++ )); do
      if [[ "${reply_:l}" == "${values[$i]:l}" || "${reply_:l}" == "${labels[$i]:l}" ]]; then
        print -r -- "${values[$i]}"
        return
      fi
    done
    print -u2 "  Please enter a number between 1 and ${#values}."
  done
}

prompt_yes_no() {
  # $1 = prompt, $2 = default (1 = yes, 0 = no). Prints 1 or 0.
  local prompt="$1" default="$2" hint reply_
  if (( default )); then hint="Y/n"; else hint="y/N"; fi
  while true; do
    printf "%s [%s]: " "$prompt" "$hint" > /dev/tty
    read -r reply_ < /dev/tty || reply_=""
    case "${reply_:-}" in
      "") print -r -- "$default"; return ;;
      [Yy]|[Yy][Ee][Ss]) print -r -- 1; return ;;
      [Nn]|[Nn][Oo]) print -r -- 0; return ;;
      *) print -u2 "  Please answer y or n." ;;
    esac
  done
}

if (( ! ASSUME_YES )) && [[ -t 0 ]]; then
  print -P "${C_BOLD}What do you want to do?${C_RESET} ${C_DIM}(pick a number, or just hit Enter for the default)${C_RESET}"
  CONFIGURATION="$(prompt_choice "Configuration" "${CONFIGURATION}" "Debug" "Release")"
  DEST="$(prompt_choice "Install location" "${DEST}" "local|Local build (./build/Yippy)" "applications|/Applications" "custom|Custom path…")"
  if [[ "${DEST}" == "custom" ]]; then
    printf "  Enter a directory (Yippy.app goes inside) or a path ending in .app: " > /dev/tty
    read -r DEST < /dev/tty || DEST=""
    [[ -n "${DEST}" ]] || fail "no custom path entered"
  fi
  LAUNCH="$(prompt_yes_no "  Launch after building?" "${LAUNCH}")"
  print ""
fi

# Resolve the destination to a concrete Yippy.app path.
case "${DEST}" in
  local) APP_PATH="${LOCAL_DIST_DIR}/Yippy.app" ;;
  applications) APP_PATH="${APPLICATIONS_APP_PATH}" ;;
  *.app) APP_PATH="${DEST}" ;;
  *) APP_PATH="${DEST%/}/Yippy.app" ;;
esac

BUILT_APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/Yippy.app"

info "Config: ${C_BOLD}${CONFIGURATION}${C_RESET}  Dest: ${C_BOLD}${APP_PATH}${C_RESET}  Launch: ${C_BOLD}$( (( LAUNCH )) && print yes || print no )${C_RESET}"

# ---- Preflight ---------------------------------------------------------

[[ -d "${PROJECT_FILE}" ]] || fail "Xcode project not found at ${PROJECT_FILE}"
command -v xcodebuild >/dev/null || fail "xcodebuild is unavailable. Install Xcode and select it with xcode-select."
command -v open >/dev/null || fail "this script must run on macOS."

if command -v xcbeautify >/dev/null; then
  readonly HAVE_XCBEAUTIFY=1
else
  readonly HAVE_XCBEAUTIFY=0
  warn "xcbeautify not found — build output will be raw and hard to scan."
  info "Install it once with: ${C_BOLD}brew install xcbeautify${C_RESET}"
fi

# ---- Stop any running instance -----------------------------------------

stop_running_yippy() {
  osascript -e 'tell application id "dev.cosmos0118.Yippy" to quit' >/dev/null 2>&1 || true
  pkill -TERM -f '/Yippy\.app/Contents/MacOS/Yippy' >/dev/null 2>&1 || true

  local attempt
  for attempt in {1..50}; do
    if ! pgrep -f '/Yippy\.app/Contents/MacOS/Yippy' >/dev/null 2>&1; then
      return
    fi
    sleep 0.1
  done

  fail "a previous Yippy instance did not stop"
}

step "Stopping any running Yippy instance"
stop_running_yippy
ok "Stopped"

# ---- Clean --------------------------------------------------------------

step "Cleaning build intermediates"
rm -rf "${DERIVED_DATA}"
mkdir -p "${BUILD_ROOT}" "${LOCAL_DIST_DIR}" "${APP_PATH:h}"
ok "Cleaned ${DERIVED_DATA} (kept ${LOCAL_DIST_DIR})"

# ---- Build ----------------------------------------------------------------

step "Building Yippy (${CONFIGURATION})"

build_start=$(date +%s)
build_status=0

set +e
if (( HAVE_XCBEAUTIFY )); then
  xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA}" \
    -clonedSourcePackagesDirPath "${SOURCE_PACKAGES}" \
    CODE_SIGNING_ALLOWED=NO \
    clean build 2>&1 | tee "${BUILD_LOG}" | xcbeautify --disable-logging
  build_status=$?
else
  xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA}" \
    -clonedSourcePackagesDirPath "${SOURCE_PACKAGES}" \
    CODE_SIGNING_ALLOWED=NO \
    clean build 2>&1 | tee "${BUILD_LOG}"
  build_status=$?
fi
set -e

build_secs=$(elapsed_since "${build_start}")

if (( build_status != 0 )); then
  print -P "\n${C_RED}${C_BOLD}✘ BUILD FAILED${C_RESET} ${C_DIM}(${build_secs}s)${C_RESET}"
  print -P "${C_DIM}Full log: ${BUILD_LOG}${C_RESET}"

  if (( HAVE_XCBEAUTIFY )); then
    print -P "\n${C_BOLD}Errors:${C_RESET}"
    grep -E 'error:' "${BUILD_LOG}" | sed 's/^/  /' || true
  fi

  exit "${build_status}"
fi

ok "Build succeeded ${C_DIM}(${build_secs}s)${C_RESET}"

if [[ ! -d "${BUILT_APP_PATH}" ]]; then
  fail "build completed but Yippy.app was not produced at ${BUILT_APP_PATH}"
fi

# Stage a stable copy outside DerivedData: cleaning intermediates or clearing
# caches must never delete the app you launch. Only replace the stable copy
# after a successful build so a failed build can't leave you with nothing.
step "Staging stable copy"
if [[ "${APP_PATH}" == "/Applications/"* ]] && [[ ! -w "/Applications" ]]; then
  fail "${APP_PATH} is not writable. Re-run with sudo, or use --dest local."
fi
rm -rf "${APP_PATH}"
if ! ditto "${BUILT_APP_PATH}" "${APP_PATH}"; then
  fail "could not copy to ${APP_PATH}. If it's /Applications, try: sudo ${0} --dest applications"
fi
ok "Staged ${APP_PATH}"

# ---- Launch ---------------------------------------------------------------

if (( LAUNCH )); then
  step "Launching Yippy"
  open "${APP_PATH}"
  ok "Yippy is running from ${APP_PATH}"
else
  ok "Built ${APP_PATH} (not launched)"
fi
