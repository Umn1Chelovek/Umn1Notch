# Umn1Notch

**Version:** 0.5.0  
**Package:** `com.umn1notch.tweak`  
**Target:** rootless jailbreaks on iOS 15.0 and newer  
**Test device reported by the project owner:** iPhone 7 Plus, iOS 15.8.6

Umn1Notch is an experimental Dynamic Island-style overlay for iPhones with a physical notch and supported models without a built-in Dynamic Island.

## Settings

After installation, open **Settings → Umn1Notch**.

Available options:

- Enable Umn1Notch
- Island style: Auto / Wide / Compact
- Music player
- Charging indicator
- Audio accessories
- Calls
- Silent mode
- Emergency gesture: on/off
- Emergency gesture taps: 5–25
- Molten-metal hold effect: on/off
- Startup glow: on/off
- Metal heating duration: 2.5–8 seconds

Most options post a Darwin notification and are applied without a respring. The PreferenceLoader entry is packaged at `/Library/PreferenceLoader/Preferences/Umn1NotchPrefs.plist`. Its preference bundle and `Root.plist` are included in the same `.deb`; `preferenceloader` is declared as a package dependency.

## Island profiles

- **Wide:** visual profile modeled after iPhone X–12.
- **Compact:** visual profile modeled after iPhone 13–14.
- **Auto:** follows the detected physical-notch family; devices without a built-in Dynamic Island default to Wide.

On iPhone 7/7 Plus, iPhone 8/8 Plus, iPhone 6s/6s Plus and supported SE models without a built-in Dynamic Island, the island is virtual. The island style can be changed later in Settings. On supported notchless devices, a two-finger tap on the island remains as a shortcut to the style picker.

## Media player notes

The media card requests now-playing metadata from Apple's private MediaRemote framework and falls back to `SBMediaController` / `MPNowPlayingInfoCenter`, including individual SpringBoard title and artist selectors when present. Artwork is only available when the playing app publishes it. Media has the lowest event priority, so charging, connected accessories, calls, or silent mode can temporarily take precedence. Private framework availability and metadata keys can vary by iOS build, so this still needs device testing.

## Emergency gesture

The tap count is configurable from 5 to 25 in Settings; taps must happen within a 3-second window. Reaching the threshold displays a confirmation dialog. The tweak does not automatically call emergency services. The call action is only triggered after the user explicitly presses the confirmation button, and the operating system may show its own call interface.

## Build

```sh
make clean
make package FINALPACKAGE=1
```

The GitHub Actions workflow builds the root project and any additional Theos projects placed under `Tweaks/<ProjectName>/`. Add complete, uncompiled source projects there; Actions compiles them into `.deb` packages on every push.

## Adding more tweaks to this repository

Create a folder such as:

```text
Tweaks/
  ExampleTweak/
    Makefile
    control
    ExampleTweak.plist
    Tweak.x
```

Each folder must be a complete, independent Theos project and must target the same repository architecture (`iphoneos-arm64`) and rootless packaging scheme. The workflow will compile it, collect its `.deb`, and include it in the shared `Packages` index. Use a unique Debian `Package:` identifier for every tweak.

## Changing icons

- Repository/source icon: add a square PNG named `assets/CydiaIcon.png`. The workflow copies it to the repository root, where Sileo can use it as the source icon.
- Package icon: add a PNG under `assets/icons/`, then add an `Icon:` HTTPS URL to that tweak's `control` file. For Umn1Notch, for example: `Icon: https://umn1chelovek.github.io/umn1notch/icons/umn1notch.png` when the file exists at `assets/icons/umn1notch.png`.
- Settings icon: add an image to `Preferences/Resources/` and add an `icon` path to the PreferenceLoader entry file. The current project does not include a custom icon image yet.
- The package manager may cache artwork; refresh the source or remove and re-add it after replacing an icon.

## Compatibility and limitations

- One rootless package, `iphoneos-arm64` (built for `arm64` and `arm64e`).
- Minimum package firmware: iOS 15.0. This excludes older iPhones that cannot run iOS 15.
- A package deployment target does not guarantee that every private SpringBoard API remains compatible on future firmware or every jailbreak bootstrap.
- Status-bar classes, silent-switch detection, call detection, MediaRemote, and artwork access rely partly on private APIs and require real-device validation.
- The code is tailored to the reported iPhone 7 Plus / iOS 15.8.6 test case. This source revision has not been compiled or tested on-device in this environment. Confirm the GitHub Actions build and test the package on a device where recovery/uninstall is available. The music card can only show metadata/artwork that the active player publishes; charging, accessories, calls and silent mode retain their higher trigger priority and can temporarily replace the music card.
