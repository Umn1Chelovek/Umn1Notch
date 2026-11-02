# Contributing tweaks

1. Create `Tweaks/YourTweak/`.
2. Add a complete Theos project with `Makefile` and `control`.
3. Use a unique lowercase Debian package identifier (for example `com.author.yourtweak`).
4. Set `THEOS_PACKAGE_SCHEME = rootless`, `ARCHS = arm64 arm64e`, and a deployment target that matches the APIs you use.
5. Ensure the resulting `.deb` reports `Architecture: iphoneos-arm64`.
6. Test installation and removal on a recoverable test device before publishing.
7. Push to `main`; Actions builds every complete project folder and republishes the common Sileo index.

Do not commit `.theos/`, `packages/`, build products, private signing keys, or personal device data.
