# Example Theos tweak template

Copy this folder to a new direct child of `Tweaks/`, remove the `.example` suffixes, and edit the project names and package identifier.

The automation ignores this folder until you create files named exactly `Makefile` and `control`.

Before publishing, use a unique `Package:` identifier, set a correct firmware minimum, and target the repository architecture `iphoneos-arm64` with `THEOS_PACKAGE_SCHEME = rootless`.
