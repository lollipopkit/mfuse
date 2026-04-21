# MFuse

[English README](README.md) | [License](LICENSE) | [Third-Party Notices](THIRD_PARTY_NOTICES.md)

> 提示
> 当前项目仍在积极开发中，行为、接口和支持的工作流都可能发生变化。

MFuse 是一个 macOS 应用，通过 File Provider 把远端存储暴露到 Finder 中，并用模块化后端支持多种协议。

## 截图

<table>
  <tr>
    <td valign="top" width="28%">
      <img src="docs/pics/app.png" alt="MFuse app UI">
    </td>
    <td valign="top" width="32%">
      <img src="docs/pics/menubar.png" alt="MFuse menubar status">
    </td>
  </tr>
  <tr>
    <td colspan="2">
      <img src="docs/pics/finder.png" alt="MFuse mounted in Finder">
    </td>
  </tr>
</table>

## 项目简介

MFuse 由三部分组成：macOS 主应用、File Provider extension，以及一组按协议拆分的 Swift Package。

主应用负责连接配置、凭证管理和用户操作；File Provider extension 负责把远端内容接入 Finder；各类远端协议则通过统一的虚拟文件系统接口接入，形成一致的使用方式。

## 当前支持的后端

- SFTP
- S3
- WebDAV
- SMB
- FTP
- NFS
- Google Drive

## 工作原理

项目主要分为三层：

- `MFuse/`：macOS SwiftUI 主应用，负责连接管理与交互界面。
- `MFuseProvider/`：File Provider extension，负责把远端内容暴露给 Finder。
- `Packages/`：可复用 Swift Package，包括 `MFuseCore` 和多个协议后端实现。

连接配置通过 `SharedStorage` 在主应用和扩展之间共享，敏感凭证通过 `KeychainService` 管理。挂载逻辑由 `FileProviderMountProvider` 处理，最终以 macOS File Provider domain 的形式出现在 Finder 中。
只要连接配置仍然存在，已挂载的 domain 在应用重启后会继续保留，MFuse 也会在可写的快捷入口目录里重建对应的便捷链接。用户手动执行 Disconnect 时，会同时移除 File Provider domain 和该链接，后续启动不会自动恢复。

## 仓库结构

```text
.
├── MFuse/                  # macOS 主应用
├── MFuseProvider/          # File Provider 扩展
├── Packages/
│   ├── MFuseCore/          # 共享模型、存储、挂载抽象
│   ├── MFuseSFTP/
│   ├── MFuseS3/
│   ├── MFuseWebDAV/
│   ├── MFuseSMB/
│   ├── MFuseFTP/
│   ├── MFuseNFS/
│   └── MFuseGoogleDrive/
├── project.yml             # XcodeGen 工程定义
└── Makefile
```

## 快速开始

### 环境要求

- macOS 14+
- Xcode 15+
- Swift 5.9+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- `swiftlint`，用于 lint

### 生成 Xcode 工程

```bash
make generate
```

### 运行测试

```bash
make test
```

当前 `make test` 实际映射到 `test-stable`，只运行本地稳定的 package 测试子集。
如果需要执行完整测试矩阵，请使用 `make test-all`。

### 运行 lint

```bash
make lint
```

### 构建应用

```bash
make build
```

### 本地 Xcode 构建

如果你是在 Xcode 里直接构建 `MFuse.app`，然后再复制到 `/Applications`，主应用 target 和 File Provider extension target 都需要使用有效的 Apple development team 签名。

未签名或 ad hoc 签名的构建虽然可以启动，但 macOS 可能会在运行时忽略 File Provider extension，因为 App Group entitlement 不会被系统接受。出现这种情况时，mount 会失败，Finder 还可能对自动生成的便捷链接报“文件不存在”。

## 常用命令

```bash
make generate   # 根据 project.yml 重新生成 MFuse.xcodeproj
make test       # 运行稳定的 package 测试子集（test-stable 别名）
make test-all   # 运行完整 package 测试矩阵
make lint       # 运行 SwiftLint
make build      # 构建应用 scheme
make clean      # 清理构建产物
```

## 本机构建 DMG

仓库现在提供本机发布脚本，用于在你的 Mac 上构建已签名并完成 notarization 的 `DMG`：

- `scripts/release/install-apple-signing.sh`
- `scripts/release/cleanup-apple-signing.sh`
- `scripts/release/build-and-notarize-dmg.sh`
- `scripts/release/release-dmg.sh`

需要准备的本机输入：

- `APPLE_DEVELOPER_ID_APP_P12_PATH`
- `APPLE_DEVELOPER_ID_APP_P12_PASSWORD`
- `APPLE_DEVELOPER_ID_APP_PROFILE_PATH`
- `APPLE_DEVELOPER_ID_EXTENSION_PROFILE_PATH`
- `APPLE_TEAM_ID`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`
- `APPLE_NOTARY_API_KEY_PATH`

这些脚本默认会从仓库根目录加载 `.env`。如果 shell 里已经显式导出了同名环境变量，则显式环境变量优先。仓库里提供了一个起始模板 `.env.release.example`。

标准流程：

- 将 `Developer ID Application` 证书和两份 provisioning profile 安装到临时本地 keychain
- 从 `project.yml` 重新生成 `MFuse.xcodeproj`
- 以 `developer-id` 方式 archive 并 export `Release` 构建
- 生成并签名 `DMG`
- 使用 `notarytool` 提交 notarization，并在成功后执行 staple
- 自动恢复之前的默认 keychain，并清理临时签名材料

示例：

```bash
cp .env.release.example .env
# 编辑 .env

make generate
make release-dmg
```

`make release-dmg` 现在会在一次执行里完成安装、打包、公证和清理。如果你要手动控制，也可以分别执行 `make release-install-signing` 和 `make release-clean-signing`。

这里故意不包含 `PKG`。如果后续要支持，还需要单独的 `Developer ID Installer` 证书。

## 测试说明

当前测试主要集中在 Swift Package 层，重点包括：

- `MFuseCore` 的核心模型与连接管理
- `MFuseFTP` 的目录解析逻辑
- `MFuseWebDAV` 的 XML 解析逻辑

部分后端测试仍是占位或偏集成测试，因此不同协议的测试覆盖度目前还不一致。

## 许可证

MFuse 采用 GNU Affero General Public License v3.0 发布，详见 [LICENSE](LICENSE)。

第三方依赖仍然分别遵循各自原有许可证，当前汇总见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
