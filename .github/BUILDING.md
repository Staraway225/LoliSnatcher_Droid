# Building LoliSnatcher from Source

This guide covers how to build LoliSnatcher locally for development and testing.

## Prerequisites

### Flutter SDK

See `pubspec.yaml` for currently used Flutter SDK version

1. Install Flutter following the [official guide](https://docs.flutter.dev/get-started/install)
2. Verify installation:
   ```bash
   flutter --version
   flutter doctor
   ```

### Dart SDK

See `pubspec.yaml` for currently used Dart SDK version

## Clone and Setup

```bash
# Clone the repository
git clone https://github.com/NO-ob/LoliSnatcher_Droid.git
cd LoliSnatcher_Droid

# Install dependencies
flutter pub get
```

## Build Commands

### Android

```bash
# Build APK for manual install
sh ./build.sh
```

Output locations:
- APK: `build/app/outputs/flutter-apk/LoliSnatcher_[version]_[build]_[arch]_[store/github/test].apk`

### iOS

iOS builds require **macOS with Xcode** — Flutter can scaffold the `ios/` project on any host,
but only Xcode can compile it.

If you do not have a Mac, fork the repository and run the **iOS Build** workflow from the Actions
tab of your fork; it builds on a GitHub-hosted macOS runner and uploads an unsigned IPA as an
artifact. It has to be your own fork — triggering a `workflow_dispatch` workflow requires write
access to the repository. macOS runners are free for public repositories.

```bash
# Generate the empty secrets config the build expects
sh gen_config.sh

# Build an unsigned .app
flutter build ios --release --no-codesign \
  --dart-define=LS_IS_STORE=false \
  --dart-define-from-file=./config/secrets.json

# Ad-hoc sign - see the note below, this step is not optional
APP=build/ios/iphoneos/Runner.app
find "$APP/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -print0 \
  | while IFS= read -r -d '' f; do codesign --force --sign - "$f"; done
find "$APP" -maxdepth 1 -name '*.bundle' -print0 \
  | while IFS= read -r -d '' b; do codesign --force --sign - "$b"; done
codesign --force --sign - "$APP"

# Package it as an .ipa
mkdir -p build/ipa/Payload
ditto "$APP" build/ipa/Payload/Runner.app
(cd build/ipa && zip -qry ../LoliSnatcher_unsigned.ipa Payload)
```

> **Why the ad-hoc signing step matters.** `--no-codesign` sets
> `CODE_SIGNING_ALLOWED=NO`, which suppresses even the ad-hoc signature the linker
> normally applies to arm64 binaries, leaving most Mach-Os with no
> `LC_CODE_SIGNATURE` load command at all. Sideloading tools can replace an
> existing signature but fail when they have to insert the load command and grow
> `__LINKEDIT` from scratch — SideStore reports this as
> `ldid.cpp(1461): _assert(): end >= size - 0x10`. Signing with `-` needs no
> certificate and creates the slot the real signature later replaces.

Output location:
- IPA: `build/LoliSnatcher_unsigned.ipa`

The CI workflow names its artifact
`LoliSnatcher_[version]_[build]_[short commit hash]_unsigned.ipa`. The build number only moves on
an explicit version bump, so the commit hash is what tells two IPAs apart.

The IPA is **unsigned on purpose**. Sign and install it with
[Sideloadly](https://sideloadly.io/) or [AltStore](https://altstore.io/) using your own Apple ID.
A free Apple ID signature lasts 7 days before the app must be re-signed.

CocoaPods resolves the plugin pods on the first build; the `Podfile` is generated at that point
and is not checked in. The deployment target is iOS 13.0, set in `ios/Runner.xcodeproj`.

## Running in Debug Mode

```bash
# Run app on connected device/emulator
flutter run

# Run on specific device
flutter devices              # List available devices
flutter run -d <device_id>   # Run on specific device
```

## Code Generation

Some features (i.e. localization changes) require code generation. Run after modifying relevant files:

```bash
# Generate localization types (after editing i18n JSON files)
dart run ./loc_build.dart

# General build runner (if needed)
dart run build_runner build
```

## IDE Setup

### VS Code

1. Install [Flutter](https://marketplace.visualstudio.com/items?itemName=Dart-Code.flutter) and [Dart](https://marketplace.visualstudio.com/items?itemName=Dart-Code.dart-code) extensions
2. Open the project folder
3. VS Code will detect Flutter project automatically
4. Use `F5` to run/debug

## Additional Resources

- [Flutter Documentation](https://docs.flutter.dev/)
- [Dart Documentation](https://dart.dev/guides)
- [Our Discord](https://discord.gg/yD47ANdEXW) for help
