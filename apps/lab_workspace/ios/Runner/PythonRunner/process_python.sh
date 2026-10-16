#!/bin/bash
set -eu

# Invoke from an Xcode Run Script phase after Copy Bundle Resources and before
# Embed Frameworks. The official CPython helper selects the correct device or
# simulator slice and converts dynamic modules to signed .framework bundles.
if [[ -z "${PROJECT_DIR:-}" || -z "${DERIVED_FILE_DIR:-}" ]]; then
  echo "Python runner packaging requires PROJECT_DIR and DERIVED_FILE_DIR from Xcode."
  exit 1
fi

python_xcframework="${PROJECT_DIR}/Python.xcframework"
if [[ ! -d "${python_xcframework}" ]]; then
  echo "Python 3.15.0 XCFramework is not installed. Run tooling/release/prepare_ios_python.sh before building iOS."
  exit 1
fi

build_utils="${python_xcframework}/build/build_utils.sh"
if [[ ! -f "${build_utils}" ]]; then
  echo "The Python XCFramework is missing its official build utilities: ${build_utils}"
  exit 1
fi

repo_root="$(cd "${PROJECT_DIR}/../../.." && pwd)"
python_source="${repo_root}/python"
app_sources="${PROJECT_DIR}/app"
if [[ ! -d "${python_source}/lab_workspace_calculation" || ! -d "${python_source}/mobile" ]]; then
  echo "The trusted calculation Python source packages are missing from ${python_source}."
  exit 1
fi

if [[ -e "${app_sources}" ]]; then
  echo "Refusing to overwrite existing iOS Python app source directory ${app_sources}."
  exit 1
fi
mkdir -p "${app_sources}"
cleanup() { rm -rf "${app_sources}"; }
trap cleanup EXIT
cp -R "${python_source}/lab_workspace_calculation" "${app_sources}/"
cp -R "${python_source}/mobile" "${app_sources}/"

# This script copies the matching CPython runtime and app code into the app
# bundle and performs the iOS framework/signing metadata transformation.
source "${build_utils}"
cd "${PROJECT_DIR}"
install_python "Python.xcframework" "app"
