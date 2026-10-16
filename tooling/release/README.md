# GitHub Actions native client artifacts

`.github/workflows/build-native-clients.yml` builds the native clients on a push
to `master` or `main`, or through the Actions **Build native clients**
`workflow_dispatch` entry. It pins Flutter to 3.47.7 and resolves the committed
app lockfile with `flutter pub get --enforce-lockfile`. The workflow does not
run tests.

Each successful platform job uploads a separate 14-day Actions artifact:

| Artifact | Contents | Signing status |
| --- | --- | --- |
| `Lab-Workspace-Windows-x64-unsigned` | ZIP of the unpackaged Windows x64 runner directory, including `lab_workspace.exe` and required Flutter/plugin DLLs | Unsigned development output; not an MSIX installer |
| `Lab-Workspace-Android-debug-APK` | Flutter debug APK with the Chaquopy-bundled trusted Python runtime | Debug/development build; not a store release |
| `Lab-Workspace-iOS-simulator-unsigned` | ZIP containing the iOS Simulator `Runner.app` | Unsigned simulator build; not a device IPA or App Store release |

The iOS job downloads the official CPython 3.15.0 iOS XCFramework through
`prepare_ios_python.sh`, verifies its fixed SHA-256, and packages the trusted
Python modules using CPython's `install_python` helper. No signing credentials
or repository secrets are used. The Windows and Android jobs do not generate or
use organization release keys.

The workflow is a cloud-build definition, not prior evidence of successful
builds. Its first Actions run is the platform build verification step.
