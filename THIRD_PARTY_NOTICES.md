# 第三方软件声明

Lithe 本体以 GPL-3.0-or-later 发布，完整条款见仓库根目录 `LICENSE`。Lithe 的 App 包还包含下列第三方命令行工具；每个项目仍受其各自的版权、许可证、notice 与专利条款约束。

本文件是索引，不替代随 App 和源码仓库提供的许可证原文。`build.sh` 会把 `Vendor/licenses/` 中列出的全部文件复制到 `Lithe.app/Contents/Resources/Licenses`。

## OxiPNG 10.2.0

- 上游：https://github.com/oxipng/oxipng/tree/v10.2.0
- 用途：PNG 无损优化。
- 许可证：MIT。
- 原文：`Vendor/licenses/OxiPNG-LICENSE.txt`。

Lithe 将上游官方 arm64 和 x86_64 macOS 发布二进制合并为 universal `oxipng`；两个发布包的 SHA-256 固定在 `vendor-oxipng.sh`。

## pngquant 3.0.3

- 上游 crate：https://static.crates.io/crates/pngquant/pngquant-3.0.3.crate
- 已发布 crate VCS commit：`2e953d9cbc282393022038673856623dcbeb389a`
- 用途：PNG 有损调色板量化。
- 主要许可证：GPL-3.0-or-later；继承的早期 pngquant/libimagequant 代码还带有相应 BSD 条款。
- 完整版权与许可证：`Vendor/licenses/pngquant-COPYRIGHT.txt`。

随 `pngquant` 静态链接的直接依赖：

- libpng 1.6.58：PNG Reference Library License v2；原文为 `Vendor/licenses/pngquant-libpng-LICENSE.txt`。
- Little CMS 2.19.1：MIT；原文为 `Vendor/licenses/pngquant-lcms2-LICENSE.txt`。

Rust 依赖的精确版本、crate 校验和及许可证文本保存在：

- `Vendor/licenses/pngquant-Cargo.lock`
- `Vendor/licenses/pngquant-DEPENDENCY-LICENSES.txt`
- `Vendor/licenses/pngquant-SOURCE-MANIFEST.txt`

依赖许可证表达式包括适用的 GPL-3.0-or-later、MIT、Apache-2.0、zlib、libpng、CC0-1.0 与 MIT-0 组合。zlib 与 iconv 使用 macOS 系统库。

## Jpegli / cjpegli

- 上游：https://github.com/google/jpegli
- 固定 commit：`031a0077f5799a6041004267fc12b956c1f52a20`
- 用途：高质量 JPEG 编码。
- 许可证：BSD-3-Clause。
- 许可证：`Vendor/licenses/Jpegli-LICENSE.txt`。
- 构建与来源 notice：`Vendor/licenses/Jpegli-NOTICE.txt`。
- 上游附加专利授权：`Vendor/licenses/Jpegli-PATENTS.txt`。

静态链接或输入层使用的第三方源码与对应原文：

- Highway：Apache-2.0 OR BSD-3-Clause，特定文件为 CC0-1.0；`Vendor/licenses/Jpegli-Highway-LICENSE.txt`。
- skcms：BSD-3-Clause；`Vendor/licenses/Jpegli-skcms-LICENSE.txt`。
- zlib：zlib License；`Vendor/licenses/Jpegli-zlib-LICENSE.txt`。
- libpng：PNG Reference Library License v2 / historical v1 terms；`Vendor/licenses/Jpegli-libpng-LICENSE.txt`。
- libjpeg-turbo compatibility source：IJG、Modified BSD-3-Clause 及适用的 zlib 条款；`Vendor/licenses/Jpegli-libjpeg-turbo-LICENSE.md`。
- APNG Disassembler 2.8：zlib License；`Vendor/licenses/Jpegli-apngdis-LICENSE.txt`。

`Jpegli-PATENTS.txt` 是随当前 Jpegli 上游源码提供的 Additional IP Rights Grant (Patents)，其终止条件和授权范围以原文为准。

## jpegtran / libjpeg-turbo 3.2.0

- 上游：https://github.com/libjpeg-turbo/libjpeg-turbo/releases/tag/3.2.0
- 用途：JPEG 无损转码与优化。
- 许可证：IJG License + Modified BSD-3-Clause；部分内部组件的更宽松条款按上游说明适用。
- 完整许可证与合规说明：`Vendor/licenses/libjpeg-turbo-LICENSE.md`。
- IJG notice 与致谢：`Vendor/licenses/libjpeg-turbo-README.ijg`。

固定来源、SHA-256、静态/系统链接决策与可复现生成步骤见 `Vendor/README.md` 及四个 `vendor-*.sh` 脚本。
