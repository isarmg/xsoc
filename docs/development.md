# xsoc 开发与验证

## 工具链与质量检查

使用 Rust `1.99.0`、Git、平台 C/C++ 构建工具和 Python `3.11+`。依赖由受控 Git 来源和根锁文件记录；正式发行须按最终源码执行对应平台原生 CI。

```sh
cargo +1.99.0 fmt --all -- --check
cargo +1.99.0 clippy --locked --all-targets --all-features -- -D warnings
cargo +1.99.0 test --locked --all-features
python3 scripts/check-xcsc-source.py
python3 scripts/check-workflow-supply-chain.py
```

## 按平台构建

原生依赖、命令和输出路径见对应平台页：

- [Linux 原生包](platforms/linux.md#构建原生安装包)
- [Windows MSI](platforms/windows.md#构建原生安装包)
- [macOS PKG](platforms/macos.md#构建原生安装包)
- [Android 宿主库检查](platforms/android.md#检查-rust-目标)
- [iOS / iPadOS 宿主库检查](platforms/ios.md#检查-rust-目标)

正式打包从 `build-tools-source.json` 固定的 `xssi` 提交取得公共物料工具，只接受当前干净源码。工具按实际目标与 feature 生成 Cargo 运行依赖图，并将随包 smartmontools、原始许可、安装脚本和最终文件清单一并核验。Windows 还核对最终 MSI 的服务、注册表、环境变量及自定义动作与本次 WXS 源码一致；DEB、RPM、PKG 使用平台格式工具只读展开核验。

最终交付目录包含可与原生安装包互相核对的 SBOM、`share/package.json` 和 `share/package.sha256`。发行校验使用 SHA-256；实际 MSI/PKG 是否具有平台签名按资产说明判断。构建工具修订未固定时打包会明确失败，不能把开发夹具当作发行物料。

## 仓库与运行边界

本仓库只有一个实际 Rust 包：根 `Cargo.toml`/`Cargo.lock` 约束依赖图，`src/` 保存采集、平台服务、状态与 CLI，`tests/` 保存独立行为和传输验证。协议是独立产品的固定 Git 输入，`packaging/` 保存系统安装器与维护夹具，`scripts/` 保存构建、发行检查，`docs/` 描述当前操作和合同。大型平台模块按职责拆分，模块测试就近保存。

当前使用 xcsc 的私有状态、CLI、有界进程和持久服务日志能力。正常运行只接受当前配置与账户格式；异常状态保全后明确报错。依赖选择和原生边界见[依赖与 unsafe 审查](unsafe-audit.md)，具体公共接口见[公共支撑](common-support.md)。

客户端不提供托盘或本地网页；移动宿主库接口见[移动宿主合同](mobile-host.md)。配置候选文件、轮换、队列和诊断见[配置指南](configuration.md)。不要把授权码、客户端令牌或 OTLP 令牌写入命令参数、Shell 历史或日志；交互授权码使用隐藏输入，应使用受保护终端。

代码采用 [Apache License 2.0](../LICENSE-APACHE)。

## 编辑文档

面向使用者按安装、配置、正常使用、维护和排障组织内容；完整字段与输出集中在参考页。示例写明平台和权限，预期结果紧跟操作，秘密与数据清理提示放在对应步骤。参照 [GNU 手册建议](https://www.gnu.org/prep/standards/html_node/GNU-Manuals.html)。检查链接和命令后，运行受影响的安装包文档检查。

## 可选 OTLP

默认特性为 desktop、nvidia。需要 OTLP 的自建客户端可执行：

```sh
XSOC_BUILD_SHA="$(git rev-parse HEAD)" cargo build --locked --release --features otlp --bin xsoc
```

OTLP 在主服务确认报告后尽力导出，使用独立目标和凭据。移动端构建与宿主职责见上面的独立平台入口。


### CI parallelism and caches

Every non-documentation push, PR, dispatch and release tag still runs both the
three-platform code-check matrix and the three-platform native-package matrix.
The existing `Desktop xsoc (...)` checks aggregate both matrices and fail if
scope detection, either matrix, or a package lifecycle check fails. Publication
still depends on that aggregate plus the mobile and OTLP checks.

Cargo caches are separated by OS, architecture, Rust version, job and Cargo
manifest/lock hash. Each commit writes a new key; an older matching dependency
cache may be restored, but all Cargo commands and executable source-identity
checks run again. Cache hits never substitute for tests, inventory generation,
license/advisory checks, package extraction or lifecycle validation.

The inventory-tool cache contains only isolated source-built cargo-audit 0.22.2
and cargo-cyclonedx 0.5.9 installs. Its exact key includes OS, architecture,
Rust version and the complete installer-script hash, with no fallback key.
Misses use Cargo's locked crates.io installation; hits verify the binary SHA-256
manifest before execution and then verify each tool version. The manifest
catches incomplete/corrupt restores, not a malicious cache plus forged manifest;
GitHub's repository/ref-scoped cache permissions remain the trust boundary.
No downloaded third-party binary distribution replaces the locked source build.

The pre-optimization Windows sample took 26m30s, including 7m25s to build these
tools, 2m21s Clippy, 2m44s debug tests, 2m41s release binaries, 2m28s release-policy
tests and 5m26s MSI lifecycle. Parallel checks plus warm tool/build caches target
roughly 8–12 minutes for normal pushes. A wholly cold cache is expected to need
roughly 17–20 minutes because source-built tools and genuine MSI transitions
remain mandatory. These are estimates, not measured guarantees; compare the
exact-commit workflow timings after the first cold run and next warm run.
