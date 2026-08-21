# Lithe

[简体中文](README.zh-CN.md)

Lithe is a lightweight image compressor for macOS. It automatically compresses JPG and PNG files, while keeping detailed comparison tools available when you need them.

[Download Lithe 1.1.0](https://github.com/OM-KEN/Lithe/releases/download/v1.1.0/Lithe-1.1.0.dmg) · Requires macOS 14 or later

## Features

- Compress static JPG and PNG files.
- Compare PNG and JPEG results for opaque PNGs.
- Inspect images with synchronized zooming and panning.
- Fine-tune JPEG quality with three presets or a 10-level control.
- For PNG, prepare up to four content-dependent results and hide size-equivalent choices.
- Drag out results, reveal them in Finder, create ZIP files, or move originals to Trash with session undo.
- Keep originals safe with immutable snapshots and non-destructive output.

## Install

1. Open the downloaded DMG.
2. Drag Lithe into Applications.
3. If macOS shows a warning on first launch, right-click Lithe and choose **Open**.

## Build

```bash
./run-tests.sh
./build.sh
./package-dmg.sh
```

Build output is stored in `.build/`. The current version is defined in [`VERSION`](VERSION). See [TODO.md](TODO.md) for planned improvements.

## License

Lithe is open source under [GPL-3.0-or-later](LICENSE). Bundled dependency notices are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Another Project

[Copied](https://github.com/OM-KEN/Copied) is a complete, standalone macOS clipboard assistant that adds visual feedback and useful actions after you copy.
