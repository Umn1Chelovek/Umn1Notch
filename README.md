# DynamicNotch

Current package version: **0.3.1**.

Theos tweak prototype for SpringBoard. On iPhones with a physical notch it uses the detected device profile; on supported notchless iPhones it can display a configurable virtual notch.

## Language

- All DynamicNotch interface strings are in English.
- The project documentation and package metadata are also written in English.
- Media titles and metadata are supplied by the currently playing app and are displayed as provided by that app.

## Build target

- One package only: **rootless** (`iphoneos-arm64`).
- Deployment target: **iOS 15.0 and newer**; there is no upper firmware limit in the package metadata.
- Architectures: `arm64`, `arm64e`.
- GitHub Actions builds one `.deb` and uploads it as the `DynamicNotch-rootless-deb` workflow artifact.

The official Theos rootless scheme supports iOS 15 and later. iOS 14 is intentionally not included in this single rootless package; supporting iOS 14 would require a separate rootful build or a different jailbreak-specific packaging approach.

## Compatibility notes

The deployment target means the package is eligible for installation on iOS 15.0 and later. It does **not** guarantee that every private SpringBoard hook will work unchanged on every future iOS release. In particular, iOS 27.0.1 support must be validated against the actual jailbreak/bootstrap, SDK/toolchain and SpringBoard build available for that firmware.

## Virtual notch on older iPhones

- iPhone 7/7 Plus, iPhone 8/8 Plus, iPhone 6s/6s Plus and the original iPhone SE use a virtual notch because they have no physical notch.
- The first launch presents a selector: **Wide — iPhone X–12** or **Narrow — iPhone 13–14**.
- The selection is saved in SpringBoard preferences and persists across resprings/reboots.
- To reopen the selector, tap the virtual notch with **two fingers at the same time**.
- iPhone SE (2nd/3rd generation) are also treated as notchless devices and can use the selector.
- The package still requires iOS 15.0+. iPhone 6 and earlier cannot install this package because they cannot run iOS 15; listing their hardware identifiers in the detector does not make them supported.

## Implementation notes

- Device model is read from `hw.machine` using `sysctlbyname`.
- Enclosure colour is queried dynamically through `MGCopyAnswer` when MobileGestalt is present; unknown values fall back to a neutral colour.
- Charging, audio-route accessories, call state and media playback are observed through system frameworks.
- Silent-switch detection is best-effort and depends on a private selector being available.
- Status-bar layout uses runtime hooks against private classes. Apple can change these classes between releases, so offsets must be tested on each target OS build.
- Five taps open a confirmation dialog for a harmless demo; the tweak does not dial emergency services.
- The long-press action creates a decorative, short-lived particle burst in the UI only.

This is a starting implementation, not a claim of universal compatibility with every SpringBoard build or jailbreak bootstrap. Test on a spare device and keep a way to disable/uninstall the tweak if SpringBoard enters a restart loop.
