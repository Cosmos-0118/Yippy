#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly PROJECT_DIR="${SCRIPT_DIR:h}"
readonly PROJECT_FILE="${PROJECT_DIR}/Maccy.xcodeproj"
readonly SCHEME="Maccy"
readonly CONFIGURATION="Debug"
readonly BUILD_ROOT="${TMPDIR%/}/yippy-build"
readonly DERIVED_DATA="${BUILD_ROOT}/DerivedData"
readonly SOURCE_PACKAGES="${BUILD_ROOT}/SourcePackages"
readonly APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/Yippy.app"
readonly BUILD_LOG="${BUILD_ROOT}/xcodebuild.log"

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

step "Cleaning build artifacts"
rm -rf "${BUILD_ROOT}"
mkdir -p "${BUILD_ROOT}"
ok "Cleaned ${BUILD_ROOT}"

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

if [[ ! -d "${APP_PATH}" ]]; then
  fail "build completed but Yippy.app was not produced at ${APP_PATH}"
fi

# ---- Launch ---------------------------------------------------------------

step "Launching Yippy"
open "${APP_PATH}"
ok "Yippy is running"
