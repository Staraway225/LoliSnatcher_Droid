<div align="center">
  <img src="assets/images/app_icon.png" width="128" height="128" alt="LoliSnatcher Logo">
  <h1>LoliSnatcher</h1>
  <p><em>Client for booru imageboards. View images and videos, do batch downloads from many booru sites with extensive customization</em></p>

  [![Upstream](https://img.shields.io/badge/upstream-NO--ob%2FLoliSnatcher__Droid-blue?logo=github)](https://github.com/NO-ob/LoliSnatcher_Droid)
  [![Discord](https://img.shields.io/badge/Discord-Join-blue?logo=discord&logoColor=white)](https://discord.gg/yD47ANdEXW)
  [![License](https://img.shields.io/github/license/Staraway225/LoliSnatcher_Droid)](https://www.gnu.org/licenses/agpl-3.0.html)
</div>

> ### Fork notice
>
> This is a **modified fork** of [NO-ob/LoliSnatcher_Droid](https://github.com/NO-ob/LoliSnatcher_Droid),
> modified by [Staraway225](https://github.com/Staraway225) beginning **2 August 2026**.
>
> The modification is **iOS support** — see [Changes in this fork](#changes-in-this-fork) for the
> full list. Everything else is the work of the upstream authors, and this fork remains licensed
> under the **AGPL-3.0**, the same as upstream.
>
> This fork publishes no GitHub Releases. iOS builds are available as CI artifacts — see
> [Install](#ios). Android builds come from
> [upstream](https://github.com/NO-ob/LoliSnatcher_Droid/releases).

## Screenshots

<table>
  <tr>
    <td><img src="wiki/screenshots/losn1.png" alt="LoliSnatcher screenshot 1" width="220"></td>
    <td><img src="wiki/screenshots/losn2.png" alt="LoliSnatcher screenshot 2" width="220"></td>
    <td><img src="wiki/screenshots/losn3.png" alt="LoliSnatcher screenshot 3" width="220"></td>
    <td><img src="wiki/screenshots/losn4.png" alt="LoliSnatcher screenshot 4" width="220"></td>
  </tr>
  <tr>
    <td><img src="wiki/screenshots/losn5.png" alt="LoliSnatcher screenshot 5" width="220"></td>
    <td><img src="wiki/screenshots/losn6.png" alt="LoliSnatcher screenshot 6" width="220"></td>
    <td><img src="wiki/screenshots/losn7.png" alt="LoliSnatcher screenshot 7" width="220"></td>
    <td><img src="wiki/screenshots/losn8.png" alt="LoliSnatcher screenshot 8" width="220"></td>
  </tr>
</table>

## Features

- **Massive list of supported Booru engines** - Browse content from Danbooru, Gelbooru, e621, and many more
- **Extensive Tabs system** - Run multiple searches simultaneously with independent tab sessions, each with their own booru, tags, and scroll position. Search all your tabs using Tabs manager with detailed filters.
- **Customization** - Deep settings for UI and behavior: themes, interface, layouts, image scaling, and much more
- **Batch download** - Download multiple images/videos at once with customizable settings
- **Sync** - Sync favourites and settings across multiple devices
- **Tag management** - Favourites, filters, blacklists, and tag history
- **Privacy-First** - No data collection, all data stored locally
- **Material 3** - Modern theming with dynamic colors and dark mode

<details>
<summary><strong>Supported Booru Platforms</strong></summary>

- Danbooru

- Gelbooru

- GelbooruV1 (Booru.org)

- Moebooru

- Philomena

- Shimmie

- e621

- Szurubooru

- Hydrus Network

- Sankaku (Default and Idol)

- rule34.xyz / rule34.world

- rule34hentai

- Booru On Rails (Twibooru)

- InkBunny

- AGNPH

- FurAffinity

- Realbooru

- RainBooru

- r34world/xyz

- And more...

</details>

## Changes in this fork

The sole purpose of this fork is to add an **iOS target**, which upstream does not ship. Upstream
builds for Android, Linux and Windows; the `ios/` directory has never existed there.

- **iOS platform support** — an `ios/` Xcode project, and `Info.plist` configured to expose the
  app's Documents directory through the iOS Files app. That is how downloads are reached on iOS:
  Android's Storage Access Framework has no iOS counterpart, so instead of porting it, snatched
  files land in the app sandbox where the Files app can see them.
- **Saved media is added to the Photos library**, mirroring the Android build, where the media
  scanner makes downloads show up in the gallery. The file itself stays in the app sandbox and the
  copy in Photos is additional. Requests add-only photo access, nothing more.
  `.webm` videos are the exception — Photos cannot import them, so those remain in Files only.
- **Swift service shim** (`ios/Runner/AppDelegate.swift`) — implements the portable subset of the
  `com.noaisu.loliSnatcher/services` method channel that `MainActivity.kt` provides on Android
  (paths, cache clearing, wakelock, share sheet, saving to Photos). Everything else returns
  `notImplemented`, which the Dart layer already tolerates.
- **Capability flags** (`PlatformExt` in `lib/src/utils/extensions.dart`) — settings that cannot
  work on a given platform are now hidden rather than shown and silently failing.
- **iOS CI workflow** (`.github/workflows/ios-build.yml`) — builds an unsigned IPA on a macOS
  runner for sideloading, ad-hoc signs every binary so sideloading tools can re-sign it, and
  fails the build if any Mach-O is left without a signature.
- Two upstream bugs fixed along the way: an unguarded system-proxy lookup that could block
  startup, and a `getDocumentsPath` channel call that was never implemented on the Android side.

**Not supported on iOS:** volume-key page navigation, app restart, the disguised app-name
launcher aliases, a custom save directory, and Material You dynamic colour. Each relies on an
Android API with no iOS equivalent.

## Install

### iOS

There is no App Store build and there never will be — the app cannot meet Apple's review
guidelines. iOS builds are **unsigned IPAs that you sign yourself** with your own Apple ID.

**Option 1 — grab a prebuilt IPA.** The [iOS Build workflow runs](../../actions/workflows/ios-build.yml)
attach an unsigned `.ipa` to each run. Open the most recent successful run and download the
artifact.

> Two caveats: GitHub requires you to be **signed in** to download workflow artifacts, even on a
> public repository, and artifacts are **deleted after 90 days**. If there is no recent run, use
> option 2.

**Option 2 — build it yourself.** Fork this repository, then run the **iOS Build** workflow from
the Actions tab of *your* fork. Triggering a workflow requires write access, so it has to be your
own fork — you cannot run it here. No Mac is needed; the workflow builds on a GitHub-hosted macOS
runner. If you do have a Mac, see [BUILDING.md](.github/BUILDING.md) to build locally.

**Then, either way:** sign and install the IPA with [SideStore](https://sidestore.io/),
[AltStore](https://altstore.io/) or [Sideloadly](https://sideloadly.io/) using your own Apple ID.
SideStore is what this has actually been tested with; Sideloadly refused to talk to the test
device, so try another tool before assuming a build is broken.

With a free Apple ID the signature expires after **7 days** and the app must be re-signed; a paid
Apple Developer account extends this to a year. Reinstalling over the top preserves app data.

### Android

Android builds come from upstream — this fork does not publish its own:

[<img src="https://play.google.com/intl/en_us/badges/static/images/badges/en_badge_web_generic.png" alt="Get it on Google Play" height="90">](https://play.google.com/store/apps/details?id=com.noaisu.play.losn)
[<img src="https://raw.githubusercontent.com/Kunzisoft/Github-badge/refs/heads/main/get-it-on-github.png" alt="Get it on Github" height="90">](https://github.com/NO-ob/LoliSnatcher_Droid/releases)
[<img src="assets/images/izzyondroid_badge_padded.png" alt="Get it at IzzyOnDroid" height="90">](https://apt.izzysoft.de/packages/com.noaisu.loliSnatcher)

## Building from Source

See [BUILDING.md](.github/BUILDING.md) for instructions.

## Contributing

Contributions are welcome! Please read our [Contributing Guidelines](CONTRIBUTING.md) before submitting a pull request.

We especially welcome:
- Bug fixes
- New booru platform support
- Translations (see [localization guide](CONTRIBUTING.md#localization--translations))
- Documentation improvements

## Translation

<a href="https://poeditor.com/"> 
  <img height="64" src="https://raw.githubusercontent.com/NO-ob/LoliSnatcher_Droid/master/poeditor.png">
</a>

We are working on translating the app to other languages using [POEditor](https://poeditor.com/join/project/RgscnzeWts), please get in touch there or in our Discord server if you are interested in helping us.

## Links

- [Discord Server](https://discord.gg/yD47ANdEXW) - Community and support (upstream)
- [Privacy Policy](privacypolicy.md)
- [Report Issues with this fork](https://github.com/Staraway225/LoliSnatcher_Droid/issues) - iOS-specific problems
- [Report Issues upstream](https://github.com/NO-ob/LoliSnatcher_Droid/issues) - anything not iOS-specific

## Credits

- **LoliSnatcher** - originally created and maintained by [NO-ob](https://github.com/NO-ob) and
  [NANI-SORE](https://github.com/NANI-SORE). This fork adds iOS support on top of their work.
- **App Icon** - [Showers-U](https://www.pixiv.net/en/users/28366691) on Pixiv
- Built with [Flutter](https://flutter.dev/)

## License

This project is licensed under the **GNU Affero General Public License v3.0** - see the [LICENSE](LICENSE) file for details.

This fork is a modified version of the original and is distributed under the same licence, as
AGPL-3.0 §5 requires. The modifications are described under
[Changes in this fork](#changes-in-this-fork); the original is at
[NO-ob/LoliSnatcher_Droid](https://github.com/NO-ob/LoliSnatcher_Droid).

[![AGPL-3.0](https://www.gnu.org/graphics/agplv3-with-text-162x68.png)](https://www.gnu.org/licenses/agpl-3.0.html)
