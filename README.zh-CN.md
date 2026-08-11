# Lithe

[English](README.md)

Lithe 是一款轻量、可检查的 macOS 图片压缩工具。传入 JPG 或 PNG 后，它会自动保留安全、有效的结果；只有机器难以判断时，才需要你打开检查窗口进行比较。

> 当前源码版本记录在 [`VERSION`](VERSION) 中。需要 macOS 14 或更高版本。

## 亮点

- 使用 Jpegli、pngquant、OxiPNG 和 jpegtran 压缩静态 JPG/PNG。
- 不透明 PNG 会比较 PNG 与 JPEG，透明 PNG 始终保留透明度。
- 检查窗口支持同步缩放和平移、三档快捷质量及 10 级高级调节。
- 结果可拖出、在 Finder 中显示、打包 ZIP，或将合格原图移到废纸篓并在当前会话撤销。
- 每次处理都先创建不可变快照，不会覆盖原图或用户修改过的输出。

## 安装与使用

从 [Releases](https://github.com/OM-KEN/Lithe/releases) 下载最新版 DMG，打开后将 Lithe 拖入“应用程序”。可通过 Finder 的“打开方式”、Launch Services 或独立的 Copied 集成传入本地 JPG/PNG 文件。

## 从源码构建

安装 Xcode Command Line Tools 后执行：

```bash
./run-tests.sh
./build.sh
```

universal App 会生成在 `.build/Lithe.app`。仓库已包含全部编码工具，无需 Homebrew。

## 版本与 DMG 打包

`VERSION` 是唯一版本来源。`build.sh` 会把版本写入 App，`package-dmg.sh` 会生成 `.build/Lithe-<版本>.dmg` 及其 SHA-256 文件。

```bash
./package-dmg.sh
```

当前 GitHub 打包等级与 Copied 一致：App 使用 Apple Development 签名，DMG 尚未公证。因此部分 Mac 可能需要在 Finder 中右键选择“打开”。

```bash
LITHE_SIGN_IDENTITY="Apple Development: …" \
./package-dmg.sh --release
```

如需标准公开分发，`--release` 也支持 Developer ID Application 与 `LITHE_NOTARY_PROFILE`；该路径会签名、公证并装订 DMG 票据。

当前待办见 [TODO.md](TODO.md)，编码工具来源见 [Vendor/README.md](Vendor/README.md)。

## 许可

Lithe 以 [GPL-3.0-or-later](LICENSE) 开源。内嵌依赖的许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。Copied 是独立项目，不包含在本仓库中。
