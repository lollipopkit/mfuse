<script>
  const protocols = [
    'SFTP',
    'Amazon S3',
    'WebDAV',
    'SMB/CIFS',
    'FTP',
    'NFS',
    'Google Drive',
  ]

  const features = [
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
  ]

  const testimonials = [
    {
      quote: 'MFuse replaced three mounting tools in our stack while keeping Finder behavior instantly familiar to every team.',
      name: 'Papercube',
      role: 'iOS Developer',
    },
    {
      quote: 'Onboarding remote storage workflows now takes hours, not weeks. The backend abstraction is genuinely clean.',
      name: 'wyy',
      role: 'Infrastructure Lead',
    },
    {
      quote: 'Teams move content between S3 and SMB with fewer handoff errors and tighter operational visibility.',
      name: 'Eurafat45',
      role: 'Student',
    },
  ]
</script>

<main class="site">
  <header class="site-nav" id="top">
    <a class="brand" href="#top">MFuse</a>
    <nav>
      <a href="#features">Features</a>
      <a href="#protocols">Protocols</a>
      <a href="#testimonials">Testimonials</a>
    </nav>
    <a class="nav-cta" href="#homebrew">Download</a>
  </header>

  <section class="hero" id="hero">
    <h1>Remote filesystems,<br />native macOS speed.</h1>
    <p class="hero-subtitle">
      MFuse unifies distributed storage into one Finder-native workflow — SFTP, S3, WebDAV, SMB, FTP, NFS, and Google Drive, all mounted transparently.
    </p>
    <div class="hero-actions">
      <a class="btn btn-primary" href="#homebrew">Download for macOS</a>
      <a class="btn btn-secondary" href="#features">See how it works</a>
    </div>
  </section>

  <section class="page-section" id="features">
    <div class="section-head">
      <h2>One mount layer. Every protocol your team depends on.</h2>
      <p>
        A dense capability surface with no decorative filler — every block maps to a real operational outcome.
      </p>
    </div>

    <div class="feature-grid">
      {#each features as feature}
        <article class="feature-card" class:wide={feature.wide}>
          <div class="icon">{feature.icon}</div>
          <h3>{feature.title}</h3>
          <p>{feature.description}</p>
        </article>
      {/each}
    </div>
  </section>

  <section class="protocol-section" id="protocols">
    <div class="section-head">
      <h2>All the protocols. One native experience.</h2>
      <p>
        Each backend is a self-contained Swift package implementing the shared RemoteFileSystem interface, keeping protocol specifics isolated from the app and the File Provider extension.
      </p>
    </div>

    <div class="protocol-badges">
      {#each protocols as proto}
        <span class="protocol-badge">{proto}</span>
      {/each}
    </div>

    <div class="code-block" id="homebrew">
      <span class="command">brew install --cask mfuse</span>
    </div>
  </section>

  <section class="page-section" id="testimonials">
    <div class="section-head">
      <h2>Trusted by teams that move fast.</h2>
    </div>

    <div class="testimonial-grid">
      {#each testimonials as t}
        <article class="testimonial-card">
          <p class="quote">"{t.quote}"</p>
          <div class="author">
            <p class="name">{t.name}</p>
            <p class="role">{t.role}</p>
          </div>
        </article>
      {/each}
    </div>
  </section>

  <section class="cta-section" id="download">
    <div class="cta-block">
      <h2>MFuse is free and open source under AGPLv3.</h2>
      <p>
        Install with Homebrew or download a packaged build from GitHub Releases. Free software, no paid lock-in.
      </p>
      <div class="cta-actions">
        <a class="btn btn-secondary" href="#homebrew">Install with Homebrew</a>
        <a class="btn btn-primary" href="https://github.com/lollipopkit/mfuse/releases">Download from GitHub Releases</a>
      </div>
    </div>
  </section>

  <footer class="site-footer">
    <span>© 2026 MFuse</span>
    <div class="footer-links">
      <a href="#features">Features</a>
      <a href="#protocols">Protocols</a>
      <a href="https://github.com/lollipopkit/mfuse">GitHub</a>
      <a href="https://github.com/lollipopkit/mfuse/releases">Releases</a>
    </div>
  </footer>
</main>
