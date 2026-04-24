export const defaultLocale = 'en'

export const locales = [
  { code: 'en', label: 'English', shortLabel: 'EN' },
  { code: 'zh-CN', label: '简体中文', shortLabel: '中' },
]

export const localeStorageKey = 'mfuse.website.locale'

export const translations = {
  en: {
    meta: {
      lang: 'en',
      title: 'MFuse — Remote filesystems, native macOS speed',
      description:
        'MFuse — Mount remote filesystems at native macOS speed. SFTP, S3, WebDAV, SMB, FTP, NFS, and Google Drive in one Finder-native workflow.',
    },
    nav: {
      features: 'Features',
      protocols: 'Protocols',
      testimonials: 'Testimonials',
      download: 'Download',
      languageLabel: 'Language',
    },
    hero: {
      titlePrefix: 'Remote filesystems,',
      titleSuffix: 'native macOS speed.',
      subtitle:
        'MFuse unifies distributed storage into one Finder-native workflow — SFTP, S3, WebDAV, SMB, FTP, NFS, and Google Drive, all mounted transparently.',
      primaryAction: 'Download for macOS',
      secondaryAction: 'See how it works',
    },
    features: {
      title: 'One mount layer. Every protocol your team depends on.',
      subtitle:
        'A dense capability surface with no decorative filler — every block maps to a real operational outcome.',
      items: [
        {
          icon: '⬡',
          title: 'Native Finder Integration',
          description:
            'Uses the macOS File Provider API so remote volumes appear, browse, and behave exactly like local folders.',
          wide: false,
        },
        {
          icon: '⬡',
          title: 'Cross-Protocol Workspace',
          description:
            'Mount SFTP, S3, WebDAV, SMB, FTP, NFS, and Google Drive side by side in a single Finder-native surface.',
          wide: true,
        },
        {
          icon: '⬡',
          title: 'Credential Isolation',
          description:
            'Protocol-specific credential handling reduces cross-system leakage risk in mixed environments.',
          wide: false,
        },
        {
          icon: '⬡',
          title: 'Transparent Metadata',
          description:
            'File size, ownership, and modified timestamps are visible before transfer, right inside Finder.',
          wide: false,
        },
        {
          icon: '⬡',
          title: 'Reliable Reconnect',
          description:
            'Predictable mount lifecycle across long-running desktop sessions and unstable network windows.',
          wide: false,
        },
      ],
    },
    protocols: {
      title: 'All the protocols. One native experience.',
      subtitle:
        'Each backend is a self-contained Swift package implementing the shared RemoteFileSystem interface, keeping protocol specifics isolated from the app and the File Provider extension.',
      installTapPrompt: '# tap the custom repo',
      installCaskPrompt: '# install MFuse',
      names: ['SFTP', 'Amazon S3', 'WebDAV', 'SMB/CIFS', 'FTP', 'NFS', 'Google Drive'],
    },
    testimonials: {
      title: 'Trusted by teams that move fast.',
      items: [
        {
          quote:
            'MFuse replaced three mounting tools in our stack while keeping Finder behavior instantly familiar to every team.',
          name: 'Papercube',
          role: 'iOS Developer',
        },
        {
          quote:
            'Onboarding remote storage workflows now takes hours, not weeks. The backend abstraction is genuinely clean.',
          name: 'wyy',
          role: 'Infrastructure Lead',
        },
        {
          quote:
            'Teams move content between S3 and SMB with fewer handoff errors and tighter operational visibility.',
          name: 'Eurafat45',
          role: 'Student',
        },
      ],
    },
    cta: {
      title: 'MFuse is free and open source under AGPLv3.',
      subtitle:
        'Install from the Homebrew tap or download a packaged build from GitHub Releases. Free software, no paid lock-in.',
      homebrewAction: 'Install from Homebrew Tap',
      githubAction: 'Download from GitHub Releases',
    },
    footer: {
      features: 'Features',
      protocols: 'Protocols',
      releases: 'Releases',
    },
  },
  'zh-CN': {
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
      items: [
        {
          icon: '⬡',
          title: 'Finder 原生集成',
          description:
            '基于 macOS File Provider API，远程卷可以像本地文件夹一样显示、浏览和操作。',
          wide: false,
        },
        {
          icon: '⬡',
          title: '跨协议工作区',
          description:
            '在同一个 Finder 原生界面中并排挂载 SFTP、S3、WebDAV、SMB、FTP、NFS 和 Google Drive。',
          wide: true,
        },
        {
          icon: '⬡',
          title: '凭据隔离',
          description:
            '按协议处理凭据，降低混合环境中跨系统泄露凭据的风险。',
          wide: false,
        },
        {
          icon: '⬡',
          title: '透明元数据',
          description:
            '传输前即可在 Finder 中查看文件大小、所有者和修改时间。',
          wide: false,
        },
        {
          icon: '⬡',
          title: '可靠重连',
          description:
            '在长时间桌面会话和不稳定网络窗口中提供可预期的挂载生命周期。',
          wide: false,
        },
      ],
    },
    protocols: {
      title: '所有协议，一个原生体验。',
      subtitle:
        '每个后端都是独立 Swift package，并实现共享的 RemoteFileSystem 接口，让协议细节隔离在 app 和 File Provider extension 之外。',
      installTapPrompt: '# 添加自定义 tap',
      installCaskPrompt: '# 安装 MFuse',
      names: ['SFTP', 'Amazon S3', 'WebDAV', 'SMB/CIFS', 'FTP', 'NFS', 'Google Drive'],
    },
    testimonials: {
      title: '受到高速协作团队信任。',
      items: [
        {
          quote:
            'MFuse 替换了我们栈里的三个挂载工具，同时让每个团队都能立刻使用熟悉的 Finder 行为。',
          name: 'Papercube',
          role: 'iOS Developer',
        },
        {
          quote:
            '远程存储工作流的 onboarding 从数周缩短到数小时，后端抽象也确实干净。',
          name: 'wyy',
          role: 'Infrastructure Lead',
        },
        {
          quote:
            '团队在 S3 和 SMB 之间移动内容时，交接错误更少，运维可见性更强。',
          name: 'Eurafat45',
          role: 'Student',
        },
      ],
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
  },
}

export function normalizeLocale(locale) {
  if (!locale) return defaultLocale
  if (translations[locale]) return locale

  const lowerLocale = locale.toLowerCase()
  if (lowerLocale.startsWith('zh')) return 'zh-CN'
  if (lowerLocale.startsWith('en')) return 'en'

  return defaultLocale
}

export function getInitialLocale() {
  const params = new URLSearchParams(window.location.search)
  const queryLocale = normalizeLocale(params.get('lang'))
  if (params.has('lang')) return queryLocale

  const storedLocale = localStorage.getItem(localeStorageKey)
  if (storedLocale) return normalizeLocale(storedLocale)

  return normalizeLocale(navigator.languages?.[0] || navigator.language)
}

export function syncLocaleToUrl(locale) {
  const url = new URL(window.location.href)
  url.searchParams.set('lang', normalizeLocale(locale))
  window.history.replaceState({}, '', url)
}
