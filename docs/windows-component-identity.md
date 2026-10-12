# Windows MSI 组件身份

XSOC 1.0.5 为自己的服务文件和状态登记使用独立、固定的组件 GUID。旧标识在用户提供的 Windows Installer 登记中同时归属另一个产品，且资源路径不同；新安装器不再使用这两个标识。该外部登记证据来自用户报告，本仓库不包含 UnionC 的真实安装包。

| 身份 | 固定 GUID | 所属资源 |
| --- | --- | --- |
| UpgradeCode | `B4A341EC-D4B2-419F-A00B-E8E504DE9798` | XSOC 的 MSI 产品家族 |
| ClientServiceComponent | `56AF4FAC-C353-598B-A680-CFBE4A86F6B2` | 所选安装目录的 `xsoc.exe`、`xsoc` 服务及其 PATH 项 |
| ClientStateDirectoryComponent | `C9DB8E14-008D-5261-831F-D51ED951BFB7` | HKLM `Software\sarmg\xsoc`，键路径为 `ManagedStateDirectory` |
| SmartmontoolsRuntimeComponent | `4FB7E776-817C-4C70-AB62-2DB7111DD15A` | XSOC 私有目录中的 `smartctl.exe` 与 `drivedb.h` |
| SmartmontoolsComplianceComponent | `67F64859-953F-411A-A6E6-A3D65466EEEF` | XSOC 私有目录中的许可证、对应源码与 NOTICE |

两个新 GUID 一次性按 UUIDv5 生成并写入 WiX 源码：命名空间为上述 UpgradeCode，名称分别为 `ClientServiceComponent:always64:xsoc.exe` 和 `ClientStateDirectoryComponent:always64:HKLM\Software\sarmg\xsoc\ManagedStateDirectory`。构建不会重新生成它们。其余标识在当前三个客户端的 WiX 源码中没有重复，且没有外部冲突证据，保持不变。

相同 x64 资源集及键路径在维修和后续版本中保持组件身份。更改资源集、名称、位置或位数时，需要按[微软组件规则](https://learn.microsoft.com/en-us/windows/win32/msi/changing-the-component-code)重新审查。修复包使用高于已发布 1.0.4 的 MSI 版本，保留同一 UpgradeCode；`MajorUpgrade` 固定在 `afterInstallInitialize`，使旧产品在事务内、安装和登记新组件之前移除，失败时仍可回滚。不得把换了组件身份的另一个安装包作为同版维修包发布。

普通卸载只移除程序、服务、产品登记和产品 PATH，保留配置、身份、凭据、队列与日志。日志租约文件仍须为预期名称的零长度安全文件，即使外部进程持有其字节锁也必须接受完整维护校验；载荷日志继续有界读取。

## 验证与边界

已有 Windows CI 调用 `Test-WixAuthoring.ps1` 与 `Test-MsiLifecycle.ps1`。前者固定所有组件身份、键路径和升级顺序；后者读取实际 MSI Component/Registry/执行序列表，并通过 `MsiEnumClients`、`MsiGetComponentPath` 和 `MsiQueryProductState` 检查真实登记。

生命周期增加了一个隔离的其他产品 MSI，使用报告中的两个旧 GUID，但安装到独立测试路径和注册表键。覆盖两种安装顺序乘两种卸载顺序，要求另一产品的文件、服务、登记不受影响。它复用当前构建的文件做未启动的服务登记，**不代表真实 UnionC 共存实测**。

升级测试只复制当前编译的 MSI 数据库：一个副本使用较低产品版本与旧组件标识，安装时使用当前维护程序建立合法状态，卸载时只运行标准 MSI 组件和服务动作；另一个仅在临时副本内，于 `RemoveExistingProducts` 后注入失败。基线副本不运行当前版本的卸载维护动作，避免用同一个当前二进制伪装两个历史版本时人为共享事务日志名称；不删除或绕过真实事务日志。检查旧产品恢复、新组件登记无残留、成功升级与维修保持当前格式状态。它验证 MSI 组件换代和标准回滚，不代表历史维护程序、历史状态格式或 HostMonitor 迁移兼容。正式安装器的完整维护动作、事务顺序和卸载测试不变，也没有故障注入动作。

真实服务先创建两个租约文件。运行中卸载保持原有验证并在外部独占读者租约；再安装和维修后、服务尚未启动时，外部独占两个零长度租约并跨卸载持有句柄。两者都必须移除 SCM、程序和产品登记并保留状态与日志；所有句柄在 `finally` 中解锁关闭。

这些破坏性测试仅允许一次性的 GitHub-hosted Windows runner。Linux 的源码/XML 检查不替代实际 Windows MSI 验收。已有跨产品组件登记混用或孤立服务的机器仍需独立核对；修复不改写其他产品的登记，不自动迁移 HostMonitor，也不清理历史残留。
