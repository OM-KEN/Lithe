# 内嵌压缩工具

Lithe 的发布包包含四个 arm64 + x86_64 universal 命令行工具。`build.sh` 将它们复制到 `Lithe.app/Contents/Resources/Tools` 并与 App 一起签名。运行时只会执行 App 资源目录中的固定工具，不搜索 Homebrew、`PATH` 或其他外部安装；工具不可用或候选验证失败时，压缩引擎使用 ImageIO 的保守后备路径。

## 固定版本与官方来源

| App 内工具 | 固定上游 | 官方输入与 SHA-256 | 主要许可证 | 生成脚本 |
|---|---|---|---|---|
| `oxipng` | OxiPNG 10.2.0 | 官方 arm64 发布包 `9aad3927d095b6ade2aacb92b89ebaca442483c1f7cde5d7a2486b283c2ed5f9`；官方 x86_64 发布包 `c45acf40a70cc02539c55555ac240bf5ef24544b7ea9959d22da19f606cec205` | MIT | `vendor-oxipng.sh` |
| `pngquant` | pngquant 3.0.3 | 官方 crates.io crate `68a12bdd8825f9989f4ee9a6ab0b42727dae57728b939ef63453366697a07232`；crate VCS commit `2e953d9cbc282393022038673856623dcbeb389a` | GPL-3.0-or-later；原始 pngquant/libimagequant 部分另含 BSD 条款 | `vendor-pngquant.sh` |
| `cjpegli` | google/jpegli commit `031a0077f5799a6041004267fc12b956c1f52a20` | 官方 GitHub source archive `269b3a75d6b2da2351f7fb2d642043f60f9b6d1bd5839f20c0d7c569be073367` | BSD-3-Clause；附上游 Additional IP Rights Grant (Patents) | `vendor-jpegli.sh` |
| `jpegtran` | libjpeg-turbo 3.2.0 | 官方 source archive `6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e` | IJG License + Modified BSD-3-Clause | `vendor-jpegtran.sh` |

源码 URL、全部固定点和校验和直接写在各脚本中，并随许可证资源保留可读 provenance。生成脚本不会向系统安装工具。

## 构建与链接细节

### OxiPNG 10.2.0

`vendor-oxipng.sh` 下载 OxiPNG 官方 macOS arm64 与 x86_64 发布包，分别验证 SHA-256 后以 Apple `lipo` 合并。产物动态链接的只有 macOS 系统库 `libiconv` 与 `libSystem`。

许可证：`licenses/OxiPNG-LICENSE.txt`（MIT）。

### pngquant 3.0.3

`vendor-pngquant.sh` 使用官方 crates.io 3.0.3 crate。该 crate 的已发布 VCS commit 是 `2e953d9cbc282393022038673856623dcbeb389a`；同版本 Git tag 的目标是 `53a332a58f44357b6b41842a54d74aa1e245913d`，脚本以 crates.io 的校验和发行物为权威输入。

直接构建依赖：

- libpng 1.6.58，source SHA-256 `8c9b05b675ca7301a458df2c2e46f26e1d41ff36b8863f8c33530bc58c2e6225`，静态链接，PNG Reference Library License v2。
- Little CMS 2.19.1，source SHA-256 `bfc54f7bab59fbc921012014a8032e4cba4abd46db47d46b76416a8c0b2815c8`，静态链接，MIT。
- pngquant 的 Rust 依赖由上游 `Cargo.lock` 固定并通过 `cargo --locked` 校验；许可证表达式涵盖 GPL-3.0-or-later、MIT、Apache-2.0、zlib、libpng、CC0-1.0 与 MIT-0 的适用组合。
- zlib 与 iconv 使用 macOS 系统动态库；`libpng-sys` 与 `libz-sys` 仅作为 FFI wrapper，其旧版内置 C 源码不参与构建。

构建固定使用官方 Rust 1.85.1 发行组件。Rust 工具链只参与构建，不进入 App。完整 crate 锁文件、依赖许可证合订本和来源 manifest 分别为：

- `licenses/pngquant-Cargo.lock`
- `licenses/pngquant-DEPENDENCY-LICENSES.txt`
- `licenses/pngquant-SOURCE-MANIFEST.txt`
- `licenses/pngquant-COPYRIGHT.txt`
- `licenses/pngquant-libpng-LICENSE.txt`
- `licenses/pngquant-lcms2-LICENSE.txt`

### Jpegli `031a0077f5799a6041004267fc12b956c1f52a20`

`vendor-jpegli.sh` 为 arm64 与 x86_64 分别配置源码，再合并 `cjpegli`。脚本关闭共享库、测试、基准、模糊测试及无关可选组件，并显式禁用系统 GIF 包自动发现。Jpegli 与运行时需要的依赖静态链接，最终只有 macOS 系统 `libc++` 与 `libSystem` 动态依赖。

固定源码依赖：

| 依赖 | Commit | Source SHA-256 | 许可证 |
|---|---|---|---|
| Highway | `271a9a0ed9de1232d9117f1572c3fe28f8542ec1` | `c42bcfe44d100223ea0043acb3da6de703103ca44bfb1d46b577c90939177f5f` | Apache-2.0 OR BSD-3-Clause；特定文件为 CC0-1.0 |
| skcms | `96d9171c94b937a1b5f0293de7309ac16311b722` | `9bb4b5bba0b7c04f6c2bce9ff713d61e23c9a20c4945161ae16290498ad74627` | BSD-3-Clause |
| zlib | `51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf` | `d9e270d46252734aa49770fbc544125391617956266f220bd63216c834f3a522` | zlib License |
| libpng | `872555f4ba910252783af1507f9e7fe1653be252` | `f7ebcdc408a26d45244d9ef3d35d732a5482a77c55d1d40bf1eb748030691097` | PNG Reference Library License v2 / historical v1 terms |
| libjpeg-turbo compatibility source | `8ecba3647edb6dd940463fedf38ca33a8e2a73d1` | `ed729127097af5000bfeddc6b3e679c4363bb1618ebfc07efb6b47f576471b4b` | IJG + Modified BSD-3-Clause + applicable zlib terms |

Jpegli 的输入层还包含 APNG Disassembler 2.8（zlib License）。上游 Jpegli 的 BSD-3-Clause 许可证、版权 notice 与附加专利授权完整保存在：

- `licenses/Jpegli-LICENSE.txt`
- `licenses/Jpegli-NOTICE.txt`
- `licenses/Jpegli-PATENTS.txt`
- `licenses/Jpegli-Highway-LICENSE.txt`
- `licenses/Jpegli-skcms-LICENSE.txt`
- `licenses/Jpegli-zlib-LICENSE.txt`
- `licenses/Jpegli-libpng-LICENSE.txt`
- `licenses/Jpegli-libjpeg-turbo-LICENSE.md`
- `licenses/Jpegli-apngdis-LICENSE.txt`

构建固定使用 SHA-256 校验后的 CMake 3.27.9 universal 发行包；CMake 只参与构建，不进入 App。

### jpegtran / libjpeg-turbo 3.2.0

`vendor-jpegtran.sh` 从 libjpeg-turbo 3.2.0 官方源码构建两个静态、禁用 SIMD 的 slice，再合并 universal `jpegtran`。产物只有 macOS `libSystem` 动态依赖。脚本固定并校验 CMake 4.3.3 作为构建工具；CMake 只参与构建，不进入 App。

许可证与上游致谢：

- `licenses/libjpeg-turbo-LICENSE.md`
- `licenses/libjpeg-turbo-README.ijg`

## 复现与验证

在 macOS 14+ 和 Xcode Command Line Tools 环境中，从仓库根目录执行：

```bash
./vendor-oxipng.sh
./vendor-pngquant.sh
./vendor-jpegli.sh
./vendor-jpegtran.sh
```

各脚本的验证边界如下：

- OxiPNG：发布包 SHA-256、两个目标架构和 `--version`。
- pngquant：所有直接输入 SHA-256、`Cargo.lock`、两个 slice 的架构/LC_UUID/macOS 最低版本/动态依赖/版本，以及一次真实 PNG 压缩。
- Jpegli：所有直接输入 SHA-256、两个 slice 的架构/macOS 最低版本/动态依赖/签名、CLI 输入能力，以及真实 PPM 和 PNG 编码。
- jpegtran：源码与构建工具 SHA-256、两个目标架构、非系统动态依赖和版本。

之后运行：

```bash
./run-tests.sh
./build.sh
```

`run-tests.sh` 会执行项目核心测试、四工具的架构/系统动态依赖/身份检查，以及真实 PNG/JPEG smoke test；上面的 vendor 脚本分别负责各自产物更完整的来源与工具级验证。`build.sh` 会再次验证每个工具包含 arm64 与 x86_64，并将列入发布清单的全部许可证文件复制到 App 资源目录。
