# MFuse

[English](README.md) | [下载](https://github.com/lollipopkit/mfuse/releases) | [License](LICENSE) | [Third-Party Notices](THIRD_PARTY_NOTICES.md)

> 提示
> 当前项目仍在积极开发中，行为、接口和支持的工作流都可能发生变化。

MFuse 是一个 macOS 应用，通过 File Provider 把远端存储暴露到 Finder 中，并用模块化后端支持多种协议。

已保存的挂载现在可以单独勾选 `Auto-Mount on App Launch`。配合 `Launch at Login` 后，这些挂载会在你登录或重启 Mac 后自动重新连接。

现在保存连接时会立即预注册对应的 File Provider domain，因此即使还没有第一次挂载，系统设置里也能先看到 MFuse。`Unmount` 现在只会断开当前会话并保留 domain；只有删除已保存连接时，系统中的 domain 才会真正移除。

MFuse 现在还在设置页提供了可选的 `iCloud Sync` 总开关。只有当 `iCloud Drive` 和 `iCloud Keychain` 都可用时，MFuse 才会跨设备同步已保存的连接配置与凭据；v1 仍然不会同步 host keys。

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

## 后端说明

- SFTP 的目录枚举带有一个兼容性 fallback：当常规 SFTP 列表请求超时，或遇到某些连接级错误时，MFuse 可能会复用现有 SSH 会话，在远端主机上执行一小段 `python3` 脚本来完成目录枚举。这个 fallback 不会用于正常成功的列表请求，也不会用于权限不足或路径不存在这类错误。触发该 fallback 的远端主机需要提供 `python3`，否则目录枚举会失败。

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

### 发布

```bash
make release
```

`make release` 会从 `.env` 读取签名与公证凭据，并用当前
`git rev-list --count HEAD` 自动生成版本号：

- `MARKETING_VERSION=<MFUSE_BASE_VERSION>.<commit count>`
- `CURRENT_PROJECT_VERSION=<commit count>`

例如当 commit 数为 `2` 且 `MFUSE_BASE_VERSION=1.0` 时，发布版本号会是
`1.0.2`，构建号会是 `2`。

当前发布流程默认要求：

- `Developer ID Application` 证书已经安装在 macOS Keychain 中
- 公证凭据已经通过 `xcrun notarytool store-credentials` 存入 Keychain
- app 和 extension 对应的 provisioning profile 已安装到 `~/Library/MobileDevice/Provisioning Profiles`
- `gh` 已经登录目标仓库并具备上传 Release 资产的权限

公证成功后，`make release` 还会自动创建或更新 tag 为
`v<MARKETING_VERSION>` 的 GitHub Release，把 title 设成同名，并上传生成的
DMG 资产。

## 常用命令

```bash
make generate   # 根据 project.yml 重新生成 MFuse.xcodeproj
make test       # 运行稳定的 package 测试子集（test-stable 别名）
make test-all   # 运行完整 package 测试矩阵
make lint       # 运行 SwiftLint
make build      # 构建应用 scheme
make clean      # 清理构建产物
```

## 测试说明

当前测试主要集中在 Swift Package 层，重点包括：

- `MFuseCore` 的核心模型与连接管理
- `MFuseFTP` 的目录解析逻辑
- `MFuseWebDAV` 的 XML 解析逻辑

部分后端测试仍是占位或偏集成测试，因此不同协议的测试覆盖度目前还不一致。

## 许可证

MFuse 采用 GNU Affero General Public License v3.0 发布，详见 [LICENSE](LICENSE)。

第三方依赖仍然分别遵循各自原有许可证，当前汇总见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
