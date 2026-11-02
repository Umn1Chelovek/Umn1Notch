# Building a tweak

The repository is edited on Windows but compiled on a GitHub-hosted macOS runner. Local builds require a working Theos installation and iOS SDK.

For the main tweak:

```sh
cd Tweaks/Umn1Notch
make clean
make package FINALPACKAGE=1
```

The resulting `.deb` is written to `Tweaks/Umn1Notch/packages/`. The repository Actions workflow performs this for every complete project directory under `Tweaks/`.
