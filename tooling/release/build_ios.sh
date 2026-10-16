#!/bin/bash
set -euo pipefail

workspace="$(cd "$(dirname "$0")/../.." && pwd)"
app="${workspace}/apps/lab_workspace"
flutter="${FLUTTER_BIN:-${workspace}/.tooling/flutter/flutter/bin/flutter}"
python_framework="${app}/ios/Python.xcframework"
python_marker="${app}/ios/.python_xcframework_sha256"
python_sha256='68e98ab35cc0643ba3a227a8c7768da45c2a5e67dbe1bc26598537e96680fd19'

if [[ ! -d "${python_framework}" || ! -f "${python_framework}/Info.plist" || ! -f "${python_framework}/build/utils.sh" ]]; then
  echo 'Verified CPython 3.15.0 iOS XCFramework is missing; run tooling/release/prepare_ios_python.sh on this Mac first.' >&2
  exit 1
fi
if [[ ! -f "${python_marker}" ]] || [[ "$(tr -d '\r\n' < "${python_marker}")" != "${python_sha256}" ]]; then
  echo 'The iOS Python XCFramework verification marker is missing or has the wrong SHA-256; rerun tooling/release/prepare_ios_python.sh.' >&2
  exit 1
fi
project_file="${app}/ios/Runner.xcodeproj/project.pbxproj"
if [[ ! -f "${project_file}" ]] || ! grep -q 'Python.xcframework in Frameworks' "${project_file}" || ! grep -q 'CodeSignOnCopy' "${project_file}" || ! grep -q 'Process Python libraries' "${project_file}" || ! grep -q 'Embed Frameworks' "${project_file}"; then
  echo 'Runner.xcodeproj is missing the required Python link/embed/process phases.' >&2
  exit 1
fi
if [[ ! -f "${app}/ios/Runner/PythonRunner/process_python.sh" ]]; then
  echo 'The trusted Python bundle-processing script is missing or not executable.' >&2
  exit 1
fi

if [[ ! -x "${flutter}" ]]; then
  echo "Flutter not found: ${flutter}; set FLUTTER_BIN to Flutter 3.47.7." >&2
  exit 1
fi
if ! "${flutter}" --version | grep -q 'Flutter 3.47.7'; then
  echo 'This release script requires Flutter 3.47.7.' >&2
  exit 1
fi
for name in LAB_WORKSPACE_APPLE_TEAM_ID LAB_WORKSPACE_APPLE_PROFILE_NAME LAB_WORKSPACE_EXPORT_OPTIONS_PLIST; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing release signing variable: ${name}" >&2
    exit 1
  fi
done
if [[ ! -f "${LAB_WORKSPACE_EXPORT_OPTIONS_PLIST}" ]]; then
  echo 'The organization-provided export options plist does not exist.' >&2
  exit 1
fi
cd "${app}"
"${flutter}" build ipa --release --export-options-plist="${LAB_WORKSPACE_EXPORT_OPTIONS_PLIST}"
