# Theos tweak projects

Add each independent Theos project as a direct child folder of `Tweaks/`. The repository workflow builds every direct child that contains both `Makefile` and `control`.

- `Umn1Notch/` is the main project and is built like every other tweak.
- `_ExampleTweak/` is documentation/template material and is skipped by the workflow because its files use the `.example` suffix.

Each buildable project must produce at least one `.deb` whose architecture is `iphoneos-arm64`, and each project must use a unique Debian `Package:` ID.
