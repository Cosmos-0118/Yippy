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

if [[ ! -d "${PROJECT_FILE}" ]]; then
  print -u2 "error: Xcode project not found at ${PROJECT_FILE}"
  exit 1
fi

if ! command -v xcodebuild >/dev/null; then
  print -u2 "error: xcodebuild is unavailable. Install Xcode and select it with xcode-select."
  exit 1
fi

if ! command -v open >/dev/null; then
  print -u2 "error: this script must run on macOS."
  exit 1
fi

print "Cleaning Yippy build artifacts…"
rm -rf "${BUILD_ROOT}"
mkdir -p "${BUILD_ROOT}"

print "Building Yippy…"
xcodebuild \
  -project "${PROJECT_FILE}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA}" \
  -clonedSourcePackagesDirPath "${SOURCE_PACKAGES}" \
  CODE_SIGNING_ALLOWED=NO \
  clean build

if [[ ! -d "${APP_PATH}" ]]; then
  print -u2 "error: build completed but Yippy.app was not produced at ${APP_PATH}"
  exit 1
fi

print "Opening Yippy…"
open -n "${APP_PATH}"
print "Yippy is running."
