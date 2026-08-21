# Lithe

[English](README.md)

Lithe 是一款轻量的 macOS 图片压缩工具。它会自动压缩 JPG 和 PNG，需要时也可以打开检查窗口仔细比较结果。

[下载 Lithe 1.1.0](https://github.com/OM-KEN/Lithe/releases/download/v1.1.0/Lithe-1.1.0.dmg) · 需要 macOS 14 或更高版本

## 功能

- 压缩静态 JPG 和 PNG 图片。
- 为不透明 PNG 比较 PNG 与 JPEG 结果。
- 在检查窗口中同步缩放和平移图片。
- JPEG 可使用三档快捷质量或 10 级高级调节。
- PNG 会按图片内容准备最多四个有明显体积差异的真实结果，避免重复档位。
- 拖出结果、在 Finder 中显示、创建 ZIP，或将原图移到废纸篓并在当前会话撤销。
- 通过不可变快照保护原图，始终以非破坏方式生成结果。

## 安装

1. 打开下载的 DMG。
2. 将 Lithe 拖入“应用程序”。
3. 如果首次启动出现 macOS 提示，请右键 Lithe，选择“打开”。

## 构建

```bash
./run-tests.sh
./build.sh
./package-dmg.sh
```

构建产物位于 `.build/`。当前版本记录在 [`VERSION`](VERSION) 中，后续计划见 [TODO.md](TODO.md)。

## 许可

Lithe 以 [GPL-3.0-or-later](LICENSE) 开源，内嵌依赖的许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 另一个项目

[Copied](https://github.com/OM-KEN/Copied) 是一款完整、独立的 macOS 剪贴板助手，在复制后提供直观反馈和快捷操作。
