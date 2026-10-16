# Trusted iOS calculation runtime

The iOS calculation bridge embeds the official CPython 3.15.0 iOS XCFramework. It invokes only the fixed `mobile.calculation_mobile_bridge.handle_json` entry point with typed JSON-RPC requests; it does not expose a REPL, shell, arbitrary module import, or runtime package installation.

The runtime matrix is pinned to **CPython 3.15.0** on iOS and Android. Python.org published CPython 3.15.0 on **2026-10-09**. Run `bash tooling/release/prepare_ios_python.sh` on macOS to fetch the fixed [official release archive](https://www.python.org/ftp/python/3.15.0/python-3.15.0-iOS-XCFramework.tar.gz), verify Python.org's published SHA-256 `68e98ab35cc0643ba3a227a8c7768da45c2a5e67dbe1bc26598537e96680fd19`, and install it at `apps/lab_workspace/ios/Python.xcframework`. The archive and installed runtime are ignored by Git; the script writes a digest marker which the iOS release script requires. Pin this release version; do not fetch a moving `latest` artifact during builds.

`Runner.xcodeproj` already links `Python.xcframework`, embeds it with **Embed & Sign**, sets the framework/header search paths and quoted include warning setting, and includes both Objective-C runner files in the Runner target. Its `Process Python libraries` phase runs after Copy Bundle Resources and before Embed Frameworks with dependency analysis disabled and User Script Sandboxing off. The host calls `probeJSONRPC` / `handleJSONRPC:error:` through `lab_workspace/calculation_executor` on its dedicated calculation queue.

That Xcode phase invokes the checked-in script:

```sh
bash "$PROJECT_DIR/Runner/PythonRunner/process_python.sh"
```

The script stages only the two trusted Python packages in the project-root `app` input folder for the duration of the packaging step, then calls the official `build/build_utils.sh` and `install_python` helpers. They place the runtime in `Runner.app/python`, the packages in `Runner.app/app`, and process standard-library binary modules for iOS framework loading and signing. The release script fails before invoking Flutter if the runtime digest marker or Xcode wiring is missing. An Apple build host and Xcode are required for release signing.

The runtime source is Python 3.15.0, matching Android Chaquopy **17.1.0**, which was released **2026-10-12** and bundles Python 3.15.0. The [official Chaquopy version matrix](https://chaquo.com/chaquopy/doc/current/versions.html) lists Python 3.10–3.15, Android Gradle Plugin 7.3–9.4, and min API 24 for 17.1. The [official Android setup](https://chaquo.com/chaquopy/doc/current/android.html) pins the Gradle plugin marker to `com.chaquo.python:com.chaquo.python.gradle.plugin:17.1.0` (plugin id `com.chaquo.python`, version `17.1.0`); keep that exact version in the host plugin declaration and keep this fragment's Python setting at `3.15`. The [17.1.0 changelog](https://chaquo.com/chaquopy/doc/current/changelog.html) confirms Python 3.15 support and the bundled Python runtime version `3.15.0`.

Both mobile runtimes include the Python standard-library `decimal` module used by the reference arithmetic. CPython documents `decimal` as part of its [3.15 standard library](https://docs.python.org/3.15/library/decimal.html). Chaquopy documents that it supports the entire standard library except its explicit [Android unsupported-module list](https://chaquo.com/chaquopy/doc/current/android.html#python-standard-library), which does not include `decimal`. CPython's [iOS embedding guide](https://docs.python.org/3.15/using/ios.html) documents the `Python.xcframework` and `install_python` flow used by this runner.

Python on iOS runs embedded in the app; no `python` executable, subprocess, or `pip` installation is available or promised at runtime. If the XCFramework is absent, the native wrapper reports the trusted Python capability as unavailable. Android/iOS include only the repository's trusted calculation modules and the supported standard library; no runtime package installation is configured. This Windows workspace cannot produce or sign the Apple XCFramework; an Apple build host and Xcode are required to complete that step.

## Official version sources

- [Python.org: CPython 3.15.0 release](https://www.python.org/downloads/release/python-3150/) — release date, iOS archive and published SHA-256.
- [CPython 3.15 iOS embedding documentation](https://docs.python.org/3.15/using/ios.html) — supported embedding workflow and runtime layout.
- [Chaquopy 17.1 version summary](https://chaquo.com/chaquopy/doc/current/versions.html) — supported Python, Android Gradle Plugin, and min API matrix.
- [Chaquopy 17.1.0 changelog](https://chaquo.com/chaquopy/doc/current/changelog.html) — release date and Python 3.15.0 runtime.
- [Chaquopy Android setup and standard library support](https://chaquo.com/chaquopy/doc/current/android.html) — pinned Gradle plugin and explicit unsupported standard-library modules.
- [Python 3.15 `decimal` documentation](https://docs.python.org/3.15/library/decimal.html) — standard-library Decimal semantics.

No build, test, or application run was performed for this runtime integration.
