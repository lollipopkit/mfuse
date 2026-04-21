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

## 当前支持的后端

- SFTP
- S3
- WebDAV
- SMB
- FTP
- NFS
- Google Drive

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

不要依赖直接修改生成后的 Xcode 工程。`MFuse.xcodeproj` 是从 `project.yml` 重新生成的，所以你在 Xcode 里手动改的签名设置，下一次执行 `make generate` 时可能会丢失。

如果你要稳定保留本机签名配置，复制 `project.local.example.yml` 为 `project.local.yml`，填入你本机的 `DEVELOPMENT_TEAM`，然后重新生成工程。`project.local.yml` 已被 Git 忽略，`make generate` 会自动把它合并进去。

未签名或 ad hoc 签名的构建虽然可以启动，但 macOS 可能会在运行时忽略 File Provider extension，因为 App Group entitlement 不会被系统接受。出现这种情况时，mount 会失败，Finder 还可能对自动生成的便捷链接报“文件不存在”。

## 常用命令

```bash
make generate   # 根据 project.yml 重新生成 MFuse.xcodeproj
make test       # 运行稳定的 package 测试子集（test-stable 别名）
make test-all   # 运行完整 package 测试矩阵
make lint       # 运行 SwiftLint
make build      # 构建应用 scheme
make release-install-app   # 构建已签名 Release 并安装到 /Applications/MFuse.app
make clean      # 清理构建产物
```

`make release-install-app` 会执行 `scripts/release/build-and-install-app.sh`：先以 `Release` 配置归档 `MFuse` scheme，再用显式 provisioning profile 重新签名导出，校验 embedded profile 已授权共享 App Group，最后才安装到 `/Applications/MFuse.app`。

这个本地安装流程要求主应用 `com.lollipopkit.mfuse` 和扩展 `com.lollipopkit.mfuse.provider` 都有显式 provisioning profile，并且它们的 `com.apple.security.application-groups` 里都包含 `group.com.lollipopkit.mfuse.shared`。

通用的 `Mac Team Provisioning Profile: *` 不够用。它不包含 App Group entitlement，在 macOS Sequoia 上会导致 “would like to access data from other apps” 启动弹窗、系统设置里看不到 File Provider 扩展，以及 Finder 挂载为空或被带到共享容器。安装脚本现在会直接失败，而不是继续把这种损坏签名的构建复制到 `/Applications`。

如果你只是想本地验证而不覆盖系统 Applications，可以改写安装目标：

```bash
INSTALL_PATH=/tmp/MFuse.app make release-install-app
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
