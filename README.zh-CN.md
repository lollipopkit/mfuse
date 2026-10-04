# MFuse

[English](README.md) | [下载](https://github.com/lollipopkit/mfuse/releases) | [License](LICENSE) | [Third-Party Notices](THIRD_PARTY_NOTICES.md)

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
- Google Drive（Google 审核通过前可能无法登录）
- Dropbox（暂不可用）
- Microsoft OneDrive（暂不可用）

Dropbox 和 OneDrive 目前在应用中已隐藏：发布版本尚未包含它们的 OAuth client ID，无法登录。已有的此类连接会保留，但无法连接。

Google Drive 使用 MFuse 的 OAuth 应用登录，该应用正在等待 Google 审核。审核通过前，登录可能被拒绝，或显示“未经验证的应用”警告。

## 后端说明

- SFTP 的目录枚举带有一个兼容性 fallback：当常规 SFTP 列表请求超时，或遇到某些连接级错误时，MFuse 可能会复用现有 SSH 会话，在远端主机上执行一小段 `python3` 脚本来完成目录枚举。这个 fallback 不会用于正常成功的列表请求，也不会用于权限不足或路径不存在这类错误。触发该 fallback 的远端主机需要提供 `python3`，否则目录枚举会失败。
- FTP 只支持被动模式（先用 `EPSV`，不支持时改用 `PASV`）；主动模式在 NAT 后无法工作。开启 TLS 时，端口 990 使用隐式 FTPS，其他端口使用显式 FTPS（`AUTH TLS`），数据连接始终加密（`PROT P`）。要求数据连接复用 TLS session 的服务器（vsftpd 的 `require_ssl_reuse=YES`、FileZilla Server 的默认设置）暂不支持：MFuse 使用的 TLS 库不支持 session 复用。
- NFS 使用 TCP 上的 NFSv3（通过 [nfs.swift](https://github.com/lollipopkit/nfs.swift)），不支持只提供 NFSv4 的服务器。远程路径填写导出的目录，通过 portmapper（端口 111）和 MOUNT 服务挂载。请求使用 `AUTH_SYS`，带上连接里设置的 UID 和 GID（默认是这台 Mac 当前用户的），来源端口大于 1024（File Provider extension 无法使用更小的端口）：Linux 的 export 需要加 `insecure` 选项（例如 `/srv/nfs *(rw,insecure,no_subtree_check)`），否则服务器会拒绝挂载。NFSv3 没有服务器端复制，复制的数据会经过这台 Mac 中转。不是 UTF-8 的文件名会保留原始字节，这些字节在 Finder 里显示为占位字符。

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
│   ├── MFuseGoogleDrive/
│   ├── MFuseDropbox/
│   └── MFuseOneDrive/
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

### 配置内置 OAuth 应用

Google Drive、Dropbox 和 OneDrive 走内置 PKCE OAuth 配置（Dropbox 和 OneDrive 目前在应用中已禁用，见上文），运行前需要在 `project.local.yml`
里填入对应的应用 ID：

```yaml
settings:
  base:
    MFGOOGLE_CLIENT_ID: YOUR_GOOGLE_CLIENT_ID.apps.googleusercontent.com
    MFDROPBOX_CLIENT_ID: YOUR_DROPBOX_APP_KEY
    MFONEDRIVE_CLIENT_ID: YOUR_MICROSOFT_APP_ID
```

Google 的 client 必须是 **iOS** 类型的 OAuth client，bundle ID 为
`com.lollipopkit.mfuse`，并启用 Google Drive API、在 consent screen 中添加
`https://www.googleapis.com/auth/drive` scope。

应用内已经预置了默认回调 URI：

- Google Drive：`com.googleusercontent.apps.<client-id 前缀>:/oauth2redirect`，由 client ID 推导
- Dropbox：`com.lollipopkit.mfuse.dropbox:/oauth`
- OneDrive：`com.lollipopkit.mfuse.onedrive:/oauth`

当前首版范围：

- Dropbox：标准用户文件空间
- OneDrive：当前登录用户的默认个人盘 / 工作盘 `drive`

当前不包含：

- SharePoint 文档库和其他非默认 Microsoft Graph drive
- Dropbox Team Space / 管理员代理能力

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

### 端到端测试

`Packages/MFuseE2E` 针对真实的 SFTP（密码和密钥）、FTP、FTPS（显式和隐式）、WebDAV、SMB、NFSv3、S3 服务器执行同一组文件操作：创建、覆盖写、范围读与流式写入、中文文件名、移动、复制、递归删除。它不覆盖 File Provider extension 本身。

1. 用 `scripts/e2e/setup-vm.sh` 配置一台 Debian 13 主机，脚本会安装 OpenSSH、vsftpd、Samba、Apache WebDAV、Linux NFS 服务端和 SeaweedFS（S3）。凭据通过标准输入传入，不会保存到仓库。
2. 把对应的 `MFUSE_E2E_*` 配置写入 `~/.config/mfuse/e2e.env`（变量名见 `setup-vm.sh`）。把主机上的测试 CA 证书 `/etc/mfuse-e2e/ca.pem` 复制到本机，并用 `MFUSE_E2E_CA` 指向它；FTPS 测试只在测试进程内信任该证书。再把 `MFUSE_E2E_NFS_UID` 和 `MFUSE_E2E_NFS_GID` 设为测试用户在主机上的 ID（`id -u`、`id -g`）。
3. 运行 `make test-e2e`。未设置 `MFUSE_E2E_HOST` 时测试会跳过。

HTTPS WebDAV 暂未覆盖。

## 许可证

MFuse 采用 GNU Affero General Public License v3.0 发布，详见 [LICENSE](LICENSE)。

第三方依赖仍然分别遵循各自原有许可证，当前汇总见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
