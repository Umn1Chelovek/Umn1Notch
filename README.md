# Umn1Notch Repository

A multi-package rootless iOS tweak repository maintained by **Umn1Chelovek**.

- Sileo source: `https://umn1chelovek.github.io/umn1notch/`
- GitHub repository: `https://github.com/Umn1Chelovek/umn1notch`
- Main package: `com.umn1notch.tweak` (`Umn1Notch`)
- Package version in this snapshot: `0.4.1`
- Package architecture: `iphoneos-arm64`
- Declared minimum firmware: iOS 15.0

> Experimental project. A successful build only confirms compilation and packaging. It does not guarantee compatibility with every jailbreak bootstrap, iOS release, or private SpringBoard API. Test on a device that can be recovered and where the package can be removed.

## Repository layout

```text
umn1notch/
├── .github/workflows/main.yml
├── Tweaks/
│   ├── Umn1Notch/              # Complete Theos project
│   ├── _ExampleTweak/          # Non-building starter template
│   └── README.md
├── assets/
│   ├── CydiaIcon.png           # Sileo source icon
│   └── icons/umn1notch.png     # Main package icon
├── docs/
├── .editorconfig
├── .gitattributes
├── .gitignore
├── CHANGELOG.md
├── CONTRIBUTING.md
├── README.md
└── SECURITY.md
```

There is intentionally no `Makefile` or `control` in the repository root. **Umn1Notch itself lives at `Tweaks/Umn1Notch/`**, alongside future projects.

## Publish with GitHub Pages

1. Open repository **Settings → Pages**.
2. Set **Build and deployment → Source** to **GitHub Actions**.
3. Keep the workflow at `.github/workflows/main.yml`.
4. Push a commit to `main` or run the workflow manually from the Actions tab.
5. Wait for both `Build all Theos tweaks` and `Publish Sileo APT Repository` to succeed.

Sileo source URL:

```text
https://umn1chelovek.github.io/umn1notch/
```

The workflow builds each direct child of `Tweaks/` that contains both `Makefile` and `control`, validates unique package IDs and `iphoneos-arm64`, creates `Packages`, `Packages.gz`, and a checksummed `Release` file, then deploys the repository to GitHub Pages.

The repository currently uses an unsigned `Release` file. For a larger public repository, add APT/GPG signing before distributing packages broadly.

## Add another tweak

Create `Tweaks/YourTweak/` as a self-contained Theos project. It must include its own `Makefile` and `control`; the workflow will then build and publish its `.deb` automatically. See `Tweaks/_ExampleTweak/README.md` and `CONTRIBUTING.md`.

Every package must use a unique Debian `Package:` identifier and target rootless `iphoneos-arm64`. Do not place compiled `.deb` files in the source tree; the workflow collects them from each Theos project's `packages/` directory.

## Icons

- Repository/source icon: `assets/CydiaIcon.png`
- Package icon: `assets/icons/umn1notch.png`
- Umn1Notch's `control` file contains the HTTPS package icon URL.

To replace either icon, overwrite the corresponding PNG and push the change. Sileo may cache artwork; refresh the source if the new image does not appear immediately.

## Local build (macOS/Linux with Theos)

```sh
cd Tweaks/Umn1Notch
make clean
make package FINALPACKAGE=1
```

Windows users can edit the repository with GitHub Desktop or another Git client; GitHub Actions performs the Theos build on a hosted macOS runner.
