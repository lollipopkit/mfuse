import type { Translation } from '../i18n-types.js'

const zhCN: Translation = {
  meta: {
    lang: 'zh-CN',
    title: 'MFuse — 以原生 macOS 速度挂载远程文件系统',
    description:
      'MFuse 以原生 macOS 速度挂载远程文件系统，将 SFTP、S3、WebDAV、SMB、FTP、NFS 和 Google Drive 整合进 Finder 原生工作流。',
  },
  nav: {
    features: '特性',
    protocols: '协议',
    testimonials: '用户评价',
    download: '下载',
    languageLabel: '语言',
  },
  hero: {
    titlePrefix: '远程文件系统，',
    titleSuffix: '原生 macOS 速度。',
    subtitle:
      'MFuse 将分布式存储统一到一个 Finder 原生工作流中，透明挂载 SFTP、S3、WebDAV、SMB、FTP、NFS 和 Google Drive。',
    primaryAction: '下载 macOS 版',
    secondaryAction: '了解工作方式',
  },
  features: {
    title: '一个挂载层，覆盖团队依赖的所有协议。',
    subtitle: '能力密度高，没有装饰性填充；每个模块都对应真实的运维结果。',
    nativeFinder: {
      title: 'Finder 原生集成',
      description:
        '基于 macOS File Provider API，远程卷可以像本地文件夹一样显示、浏览和操作。',
    },
    workspace: {
      title: '跨协议工作区',
      description:
        '在同一个 Finder 原生界面中并排挂载 SFTP、S3、WebDAV、SMB、FTP、NFS 和 Google Drive。',
    },
    credentials: {
      title: '凭据隔离',
      description: '按协议处理凭据，降低混合环境中跨系统泄露凭据的风险。',
    },
    metadata: {
      title: '透明元数据',
      description: '传输前即可在 Finder 中查看文件大小、所有者和修改时间。',
    },
    reconnect: {
      title: '可靠重连',
      description:
        '在长时间桌面会话和不稳定网络窗口中提供可预期的挂载生命周期。',
    },
  },
  protocols: {
    title: '所有协议，一个原生体验。',
    subtitle:
      '每个后端都是独立 Swift package，并实现共享的 RemoteFileSystem 接口，让协议细节隔离在 app 和 File Provider extension 之外。',
    installTapPrompt: '# 添加自定义 tap',
    installCaskPrompt: '# 安装 MFuse',
  },
  testimonials: {
    title: '受到高速协作团队信任。',
    papercube: {
      quote:
        'MFuse 替换了我们栈里的三个挂载工具，同时让每个团队都能立刻使用熟悉的 Finder 行为。',
      role: 'iOS Developer',
    },
    wyy: {
      quote:
        '远程存储工作流的 onboarding 从数周缩短到数小时，后端抽象也确实干净。',
      role: 'Infrastructure Lead',
    },
    eurafat45: {
      quote: '团队在 S3 和 SMB 之间移动内容时，交接错误更少，运维可见性更强。',
      role: 'Student',
    },
  },
  cta: {
    title: 'MFuse 是基于 AGPLv3 的免费开源软件。',
    subtitle:
      '可通过 Homebrew tap 安装，也可以从 GitHub Releases 下载打包版本。自由软件，没有付费锁定。',
    homebrewAction: '通过 Homebrew Tap 安装',
    githubAction: '从 GitHub Releases 下载',
  },
  footer: {
    features: '特性',
    protocols: '协议',
    releases: '版本发布',
  },
}

export default zhCN
