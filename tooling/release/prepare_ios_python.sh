#!/bin/bash
set -euo pipefail

workspace="$(cd "$(dirname "$0")/../.." && pwd)"
ios_dir="${workspace}/apps/lab_workspace/ios"
destination="${ios_dir}/Python.xcframework"
marker="${ios_dir}/.python_xcframework_sha256"
url="https://www.python.org/ftp/python/3.15.0/python-3.15.0-iOS-XCframework.tar.gz"
sha256="68e98ab35cc0643ba3a227a8c7768da45c2a5e67dbe1bc26598537e96680fd19"

if [[ -e "${destination}" || -e "${marker}" ]]; then
  echo "Refusing to overwrite an existing iOS Python runtime or verification marker." >&2
  echo "Remove both only after reviewing them, then rerun this preparation script." >&2
  exit 1
fi

temporary="$(mktemp -d "${TMPDIR:-/tmp}/lab-workspace-python.XXXXXX")"
cleanup() { rm -rf "${temporary}"; }
trap cleanup EXIT
archive="${temporary}/python-3.15.0-iOS-XCFramework.tar.gz"
extract_dir="${temporary}/extracted"
mkdir -p "${extract_dir}" "${ios_dir}"

curl --fail --location --retry 3 --output "${archive}" "${url}"
printf '%s  %s\n' "${sha256}" "${archive}" | shasum -a 256 -c
tar -xzf "${archive}" -C "${extract_dir}"

framework="$(find "${extract_dir}" -type d -name Python.xcframework -print -quit)"
if [[ -z "${framework}" || ! -f "${framework}/Info.plist" || ! -f "${framework}/build/build_utils.sh" ]]; then
  echo "Verified archive does not contain the expected Python.xcframework layout." >&2
  exit 1
fi

if ! /usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "${framework}/Info.plist" >/dev/null 2>&1; then
  echo "Python.xcframework Info.plist is missing its AvailableLibraries slices." >&2
  exit 1
fi
plist_xml="$(/usr/bin/plutil -convert xml1 -o - "${framework}/Info.plist")"
if ! grep -q 'ios-arm64' <<<"${plist_xml}" || ! grep -q 'ios-arm64_x86_64-simulator' <<<"${plist_xml}"; then
  echo "Python.xcframework must contain both iOS device and simulator slices." >&2
  exit 1
fi

mv "${framework}" "${destination}"
printf '%s\n' "${sha256}" > "${marker}"
echo "Installed verified CPython 3.15.0 iOS XCFramework at ${destination}."
