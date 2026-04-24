<script>
  import { onMount } from 'svelte'
  import LL, { setLocale } from './i18n/i18n-svelte'
  import { loadLocale } from './i18n/i18n-util.sync'
  import {
    defaultLocale,
    getInitialLocale,
    locales,
    localeStorageKey,
    syncLocaleToUrl,
  } from './lib/i18n.js'

  const protocols = ['SFTP', 'Amazon S3', 'WebDAV', 'SMB/CIFS', 'FTP', 'NFS', 'Google Drive']

  const features = [
    { key: 'nativeFinder', icon: '⬡', wide: false },
    { key: 'workspace', icon: '⬡', wide: true },
    { key: 'credentials', icon: '⬡', wide: false },
    { key: 'metadata', icon: '⬡', wide: false },
    { key: 'reconnect', icon: '⬡', wide: false },
  ]

  const testimonials = [
    { key: 'papercube', name: 'Papercube' },
    { key: 'wyy', name: 'wyy' },
    { key: 'eurafat45', name: 'Eurafat45' },
  ]

  function getLocaleBeforeRender() {
    if (typeof window === 'undefined') return undefined

    return getInitialLocale()
  }

  const initialLocale = getLocaleBeforeRender()

  if (initialLocale) {
    loadLocale(initialLocale)
    setLocale(initialLocale)
  }

  let locale = $state(initialLocale)
  let isMounted = $state(false)

  function applyLocale(nextLocale) {
    locale = nextLocale
    loadLocale(nextLocale)
    setLocale(nextLocale)
    syncLocaleToUrl(nextLocale)
    localStorage.setItem(localeStorageKey, nextLocale)
  }

  onMount(() => {
    if (!locale) {
      applyLocale(getInitialLocale())
    } else {
      applyLocale(locale)
    }

    isMounted = true
  })

  $effect(() => {
    if (!isMounted) return

    document.documentElement.lang = $LL.meta.lang()
    document.title = $LL.meta.title()
    document
      .querySelector('meta[name="description"]')
      ?.setAttribute('content', $LL.meta.description())
  })

  function handleLocaleChange(event) {
    applyLocale(event.currentTarget.value)
  }
</script>

{#if locale && isMounted}
  <main class="site">
    <header class="site-nav" id="top">
      <a class="brand" href="#top">MFuse</a>
      <nav>
        <a href="#features">{$LL.nav.features()}</a>
        <a href="#protocols">{$LL.nav.protocols()}</a>
        <a href="#testimonials">{$LL.nav.testimonials()}</a>
      </nav>
      <div class="nav-actions">
        <label class="language-switcher">
          <span class="sr-only">{$LL.nav.languageLabel()}</span>
          <select
            id="locale"
            name="locale"
            aria-label={$LL.nav.languageLabel()}
            value={locale}
            onchange={handleLocaleChange}
          >
            {#each locales as item}
              <option value={item.code}>{item.label}</option>
            {/each}
          </select>
        </label>
        <a class="nav-cta" href="#homebrew">{$LL.nav.download()}</a>
      </div>
    </header>

    <section class="hero" id="hero">
      <h1>{$LL.hero.titlePrefix()}<br />{$LL.hero.titleSuffix()}</h1>
      <p class="hero-subtitle">
        {$LL.hero.subtitle()}
      </p>
      <div class="hero-actions">
        <a class="btn btn-primary" href="#homebrew">{$LL.hero.primaryAction()}</a>
        <a class="btn btn-secondary" href="#features">{$LL.hero.secondaryAction()}</a>
      </div>
    </section>

    <section class="page-section" id="features">
      <div class="section-head">
        <h2>{$LL.features.title()}</h2>
        <p>
          {$LL.features.subtitle()}
        </p>
      </div>

      <div class="feature-grid">
        {#each features as feature}
          <article class="feature-card" class:wide={feature.wide}>
            <div class="icon">{feature.icon}</div>
            <h3>{$LL.features[feature.key].title()}</h3>
            <p>{$LL.features[feature.key].description()}</p>
          </article>
        {/each}
      </div>
    </section>

    <section class="protocol-section" id="protocols">
      <div class="section-head">
        <h2>{$LL.protocols.title()}</h2>
        <p>
          {$LL.protocols.subtitle()}
        </p>
      </div>

      <div class="protocol-badges">
        {#each protocols as proto}
          <span class="protocol-badge">{proto}</span>
        {/each}
      </div>

      <div class="code-block" id="homebrew">
        <span class="prompt">{$LL.protocols.installTapPrompt()}</span>
        <span class="command">brew tap lollipopkit/taps</span>
        <span class="prompt">{$LL.protocols.installCaskPrompt()}</span>
        <span class="command">brew install --cask mfuse</span>
      </div>
    </section>

    <section class="page-section" id="testimonials">
      <div class="section-head">
        <h2>{$LL.testimonials.title()}</h2>
      </div>

      <div class="testimonial-grid">
        {#each testimonials as t}
          <article class="testimonial-card">
            <p class="quote">&ldquo;{$LL.testimonials[t.key].quote()}&rdquo;</p>
            <div class="author">
              <p class="name">{t.name}</p>
              <p class="role">{$LL.testimonials[t.key].role()}</p>
            </div>
          </article>
        {/each}
      </div>
    </section>

    <section class="cta-section" id="download">
      <div class="cta-block">
        <h2>{$LL.cta.title()}</h2>
        <p>
          {$LL.cta.subtitle()}
        </p>
        <div class="cta-actions">
          <a class="btn btn-secondary" href="#homebrew">{$LL.cta.homebrewAction()}</a>
          <a class="btn btn-primary" href="https://github.com/lollipopkit/mfuse/releases">{$LL.cta.githubAction()}</a>
        </div>
      </div>
    </section>

    <footer class="site-footer">
      <span>© 2026 MFuse</span>
      <div class="footer-links">
        <a href="#features">{$LL.footer.features()}</a>
        <a href="#protocols">{$LL.footer.protocols()}</a>
        <a href="https://github.com/lollipopkit/mfuse">GitHub</a>
        <a href="https://github.com/lollipopkit/mfuse/releases">{$LL.footer.releases()}</a>
      </div>
    </footer>
  </main>
{/if}
