# 隐私政策

生效日期：2026 年 10 月 4 日。本译文仅供参考，如有出入，以英文版为准。

MFuse 是一款开源 macOS 应用，用于在 Finder 中挂载远程存储（SFTP、Amazon S3、WebDAV、SMB、FTP、NFS、Google Drive、Dropbox 和 OneDrive）。本政策说明 MFuse 访问哪些数据、如何使用以及存储在何处。源代码位于 [github.com/lollipopkit/mfuse](https://github.com/lollipopkit/mfuse)，本政策中的每项说明都可以对照源代码核实。

## 概要

- MFuse 完全在你的 Mac 上运行。开发者不运营任何接收你的文件、凭据或账户信息的服务器。
- MFuse 不包含任何统计分析、广告、崩溃上报或跟踪功能。
- 你的数据只会发送到你配置的存储服务；如果你开启 iCloud 同步，还会发送到你自己的 iCloud 账户。

## MFuse 访问的数据

- **连接设置**：你填写的连接名称、主机、端口、用户名、bucket、路径等。
- **凭据**：密码、私钥、访问密钥，以及 OAuth access token 和 refresh token。
- **远程文件**：你在 Finder 中浏览和使用的远程存储上的文件名、目录结构、元数据（大小、日期、类型）和文件内容。
- **账户身份**：对于 OAuth 服务（Google Drive、Dropbox、OneDrive），读取账户显示名称和邮箱地址，用于在 MFuse 中标识该连接。

## Google 用户数据

连接 Google Drive 账户时，MFuse 请求以下权限：

- `https://www.googleapis.com/auth/drive`：列出、读取、创建、修改、移动、重命名和删除你 Google Drive 中的文件。MFuse 仅在你于 Finder 或 MFuse 中进行操作时执行这些操作，使 Google Drive 以 Mac 上的文件夹形式呈现和工作。

MFuse 还会通过 Google Drive API 读取你的 Google 账户显示名称和邮箱地址，用于显示连接所属的账户。

Google 用户数据仅用于提供上述功能。具体而言，MFuse：

- 不会将 Google 用户数据传输给开发者或任何第三方；
- 不会将 Google 用户数据用于广告，也不会出售；
- 不允许任何人员读取 Google 用户数据；
- 不会将 Google 用户数据用于开发、改进或训练通用或非个性化的 AI 或机器学习模型。

MFuse 对通过 Google API 获得的信息的使用和传输，遵守 [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy)，包括其中的 Limited Use 要求。

## 数据存储位置

- **凭据**存储在 macOS 钥匙串（Keychain）中。
- **连接设置**，以及为提升 Finder 速度而缓存的文件元数据和文件内容，存储在你 Mac 上的 `~/Library/Group Containers/group.com.lollipopkit.mfuse.shared` 中。
- 与其他云存储应用相同，你在 Finder 中打开的文件也会由 macOS 保存在 `~/Library/CloudStorage` 下的 File Provider 存储中。

## iCloud 同步（可选）

iCloud 同步默认关闭。开启后，MFuse 会通过你的 iCloud Drive 同步连接设置，通过 iCloud 钥匙串同步凭据，以便在你的其他 Mac 上使用相同的连接。这些数据由 Apple 依据你的 Apple 账户和 Apple 隐私政策处理，开发者无法访问。MFuse 不会通过 iCloud 同步文件内容。

## 数据共享

MFuse 只会为执行你请求的操作而向你配置的服务（例如 Google、Dropbox、Microsoft 或你自己的服务器）发送数据；开启 iCloud 同步时，还会向 Apple 发送数据。云服务 API 均通过 HTTPS 访问。MFuse 不与其他任何方共享数据。

## 保留与删除

- 在 MFuse 中删除连接会卸载该连接，并删除其保存的凭据、缓存的文件元数据和缓存的文件内容。远程存储上的文件不受影响。
- 你可以随时在 [myaccount.google.com/connections](https://myaccount.google.com/connections) 撤销 MFuse 对你 Google 账户的访问权限。
- 如需删除 MFuse 在你 Mac 上保存的全部数据，请先在 MFuse 中删除所有连接，这会从钥匙串中删除它们的凭据。然后退出 MFuse 并删除 `~/Library/Group Containers/group.com.lollipopkit.mfuse.shared` 文件夹，或使用 `brew uninstall --zap --cask mfuse` 卸载。后两种方式本身都不会删除钥匙串中的凭据。

## 儿童

MFuse 并非面向 13 岁以下儿童，也不会有意收集其数据。

## 变更

本政策的变更会发布在本页面并更新生效日期，完整历史记录见项目的 Git 仓库。

## 联系方式

如对本政策有疑问，请在 [github.com/lollipopkit/mfuse/issues](https://github.com/lollipopkit/mfuse/issues) 提交 issue。
