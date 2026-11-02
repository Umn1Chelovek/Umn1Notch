# Sileo repository checks

After a successful GitHub Pages deployment, check these URLs in a browser:

- `https://umn1chelovek.github.io/umn1notch/`
- `https://umn1chelovek.github.io/umn1notch/Release`
- `https://umn1chelovek.github.io/umn1notch/Packages`
- `https://umn1chelovek.github.io/umn1notch/Packages.gz`

The `Release` file should contain `Architectures: iphoneos-arm64` and SHA256 entries for `Packages` and `Packages.gz`. `Packages` should contain one stanza per published `.deb`.

In Sileo, add the source URL with the trailing slash. If a source was added before a repository rename, remove the old URL and add the current one. Refresh sources after each deployment.

This repository currently publishes an unsigned `Release` file. Some APT frontends may warn about unsigned repositories. Do not bypass signature validation for unknown repositories. Configure GPG signing before inviting a wide audience to use the source.
