# Lithe

**A lightweight, reviewable image compressor for macOS.**<br>
**一款轻量、可检查的 macOS 图片压缩工具。**

[中文](#中文) · [English](#english)

## 中文

Lithe 把图片压缩变成一个简单动作：传入 JPG 或 PNG，自动生成安全、有效的结果；遇到机器难以判断的情况，再由你并排检查原图和候选图。

> 当前为早期 MVP，适合体验与开发，尚未提供正式签名和公证的安装包。

### 亮点

- 使用 Jpegli、pngquant、OxiPNG 和 jpegtran 压缩静态 JPG/PNG。
- 不透明 PNG 会比较 PNG 与 JPEG；透明 PNG 始终保留透明度。
- 检查窗口支持同步缩放、平移、三档快捷质量和 10 级高级调节。
- 结果可拖出、在 Finder 中显示、打包 ZIP，或将合格原图移到废纸篓并在当前会话撤销。
- 每次处理都先创建不可变快照；不会覆盖原图或用户修改过的输出。

### 构建

需要 macOS 14+ 和 Xcode Command Line Tools。仓库已包含 universal 编码工具，无需 Homebrew。

```bash
./run-tests.sh
./build.sh
```

构建产物位于 `.build/Lithe.app`。可通过 Finder 的“打开方式”、Launch Services 或独立的 Copied 集成传入本地 JPG/PNG 文件。

当前工作与发布前事项见 [TODO.md](TODO.md)。第三方工具来源见 [Vendor/README.md](Vendor/README.md)。欢迎提交包含测试说明的 Issue 或 Pull Request。

### 许可

Lithe 以 [GPL-3.0-or-later](LICENSE) 开源。第三方许可与声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。Copied 是独立项目，不包含在本仓库中。

## English

Lithe turns image compression into one simple action: send it a JPG or PNG, keep a safe and useful result automatically, and compare the original with its candidates only when human judgment helps.

> This is an early MVP for testing and development. A Developer ID-signed and notarized build is not available yet.

### Highlights

- Compresses static JPG/PNG files with Jpegli, pngquant, OxiPNG, and jpegtran.
- Compares PNG and JPEG for opaque PNGs while always preserving transparency.
- Provides synchronized zooming and panning, three quick quality presets, and a 10-level advanced control.
- Supports drag-out, Reveal in Finder, ZIP creation, and recoverable Move to Trash actions during the current session.
- Creates an immutable snapshot before processing and never overwrites originals or user-modified outputs.

### Build

Requires macOS 14+ and Xcode Command Line Tools. Universal codec binaries are included; Homebrew is not required.

```bash
./run-tests.sh
./build.sh
```

The app is written to `.build/Lithe.app`. Send local JPG/PNG files through Finder’s Open With menu, Launch Services, or the separate Copied integration.

See [TODO.md](TODO.md) for active work and pre-release tasks. Codec provenance is documented in [Vendor/README.md](Vendor/README.md). Issues and pull requests with clear verification notes are welcome.

### License

Lithe is available under [GPL-3.0-or-later](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled dependencies. Copied is a separate project and is not included in this repository.
