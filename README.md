# Lithe

[简体中文](README.zh-CN.md)

Lithe is a lightweight, reviewable image compressor for macOS. Send it a JPG or PNG, keep a safe and useful result automatically, and open the inspector only when human judgment helps.

> The current source version is recorded in [`VERSION`](VERSION). Requires macOS 14 or later.

## Highlights

- Compresses static JPG/PNG files with Jpegli, pngquant, OxiPNG, and jpegtran.
- Compares PNG and JPEG for opaque PNGs while preserving transparent PNGs.
- Offers synchronized comparison views, three quick presets, and a 10-level advanced quality control.
- Supports drag-out, Reveal in Finder, ZIP creation, and recoverable Move to Trash actions during the current session.
- Creates an immutable snapshot before processing and never overwrites originals or user-modified outputs.

## Install and Use

Download the latest DMG from [Releases](https://github.com/OM-KEN/Lithe/releases), open it, and drag Lithe into Applications. Send local JPG/PNG files through Finder’s Open With menu, Launch Services, or the separate Copied integration.

## Build from Source

Install Xcode Command Line Tools, then run:

```bash
./run-tests.sh
./build.sh
```

The universal app is written to `.build/Lithe.app`. All codec binaries are included; Homebrew is not required.

## Versioning and DMG Packaging

`VERSION` is the single source of truth. `build.sh` injects it into the app bundle, while `package-dmg.sh` creates `.build/Lithe-<version>.dmg` and its SHA-256 file.

```bash
./package-dmg.sh
```

The current GitHub packaging level matches Copied: the app is signed with Apple Development, while the DMG is not notarized. Gatekeeper may therefore require users to choose Open from the Finder context menu.

```bash
LITHE_SIGN_IDENTITY="Apple Development: …" \
./package-dmg.sh --release
```

For standard public distribution, `--release` also supports a Developer ID Application identity plus `LITHE_NOTARY_PROFILE`; that path signs, notarizes, and staples the DMG.

Active work is tracked in [TODO.md](TODO.md). Codec provenance is documented in [Vendor/README.md](Vendor/README.md).

## License

Lithe is available under [GPL-3.0-or-later](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled dependencies. Copied is a separate project and is not included here.
