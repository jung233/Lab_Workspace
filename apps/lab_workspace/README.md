# Lab Workspace native application

This Flutter target is intended for Windows, Android, and iOS only. It uses the shared `lab_core` package for local domain and persistence services. Each installation creates a private Vault under the operating system's application-support directory.

Flutter and Dart SDK archives are kept under the ignored workspace `.tooling/` directory. The app has a generated `pubspec.lock` with pinned package versions. Static analysis was run with Flutter 3.47.7; no app build, test, or launch was performed. Windows and Android native runner sources are hand-authored and still require platform-specific build validation.

For iOS release builds, first run `bash tooling/release/prepare_ios_python.sh` on macOS. It downloads the fixed official CPython 3.15.0 XCFramework, verifies Python.org's published SHA-256, and installs the runtime ignored by Git. `Runner.xcodeproj` already links and embeds the framework and processes its standard library and trusted packages. The release script refuses to proceed without the verified runtime. Apple signing identity, team, and provisioning profile are supplied by the organization through the release environment.
