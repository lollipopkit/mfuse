import type { BaseTranslation } from '../i18n-types.js'

const en: BaseTranslation = {
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
    nativeFinder: {
      title: 'Native Finder Integration',
      description:
        'Uses the macOS File Provider API so remote volumes appear, browse, and behave exactly like local folders.',
    },
    workspace: {
      title: 'Cross-Protocol Workspace',
      description:
        'Mount SFTP, S3, WebDAV, SMB, FTP, NFS, and Google Drive side by side in a single Finder-native surface.',
    },
    credentials: {
      title: 'Credential Isolation',
      description:
        'Protocol-specific credential handling reduces cross-system leakage risk in mixed environments.',
    },
    metadata: {
      title: 'Transparent Metadata',
      description:
        'File size, ownership, and modified timestamps are visible before transfer, right inside Finder.',
    },
    reconnect: {
      title: 'Reliable Reconnect',
      description:
        'Predictable mount lifecycle across long-running desktop sessions and unstable network windows.',
    },
  },
  protocols: {
    title: 'All the protocols. One native experience.',
    subtitle:
      'Each backend is a self-contained Swift package implementing the shared RemoteFileSystem interface, keeping protocol specifics isolated from the app and the File Provider extension.',
    installTapPrompt: '# tap the custom repo',
    installCaskPrompt: '# install MFuse',
  },
  testimonials: {
    title: 'Trusted by teams that move fast.',
    papercube: {
      quote:
        'MFuse replaced three mounting tools in our stack while keeping Finder behavior instantly familiar to every team.',
      role: 'iOS Developer',
    },
    wyy: {
      quote:
        'Onboarding remote storage workflows now takes hours, not weeks. The backend abstraction is genuinely clean.',
      role: 'Infrastructure Lead',
    },
    eurafat45: {
      quote:
        'Teams move content between S3 and SMB with fewer handoff errors and tighter operational visibility.',
      role: 'Student',
    },
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
}

export default en
