<script>
  import { onMount } from 'svelte'
  import {
    defaultLocale,
    getInitialLocale,
    locales,
    localeStorageKey,
    syncLocaleToUrl,
    translations,
  } from './lib/i18n.js'

  let locale = $state(defaultLocale)
  let isMounted = $state(false)
  let copy = $derived(translations[locale] || translations[defaultLocale])

  onMount(() => {
    locale = getInitialLocale()
    isMounted = true
    syncLocaleToUrl(locale)
  })

  $effect(() => {
    if (!isMounted) return

    document.documentElement.lang = copy.meta.lang
    document.title = copy.meta.title
    document
      .querySelector('meta[name="description"]')
      ?.setAttribute('content', copy.meta.description)
    localStorage.setItem(localeStorageKey, locale)
  })

  function handleLocaleChange(event) {
    locale = event.currentTarget.value
    syncLocaleToUrl(locale)
  }
</script>

<main class="site">
  <header class="site-nav" id="top">
    <a class="brand" href="#top">MFuse</a>
    <nav>
      <a href="#features">{copy.nav.features}</a>
      <a href="#protocols">{copy.nav.protocols}</a>
      <a href="#testimonials">{copy.nav.testimonials}</a>
    </nav>
    <div class="nav-actions">
      <label class="language-switcher">
        <span class="sr-only">{copy.nav.languageLabel}</span>
        <select
          id="locale"
          name="locale"
          aria-label={copy.nav.languageLabel}
          value={locale}
          onchange={handleLocaleChange}
        >
          {#each locales as item}
            <option value={item.code}>{item.label}</option>
          {/each}
        </select>
      </label>
      <a class="nav-cta" href="#homebrew">{copy.nav.download}</a>
    </div>
  </header>

  <section class="hero" id="hero">
    <h1>{copy.hero.titlePrefix}<br />{copy.hero.titleSuffix}</h1>
    <p class="hero-subtitle">
      {copy.hero.subtitle}
    </p>
    <div class="hero-actions">
      <a class="btn btn-primary" href="#homebrew">{copy.hero.primaryAction}</a>
      <a class="btn btn-secondary" href="#features">{copy.hero.secondaryAction}</a>
    </div>
  </section>

  <section class="page-section" id="features">
    <div class="section-head">
      <h2>{copy.features.title}</h2>
      <p>
        {copy.features.subtitle}
      </p>
    </div>

    <div class="feature-grid">
      {#each copy.features.items as feature}
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
      <h2>{copy.protocols.title}</h2>
      <p>
        {copy.protocols.subtitle}
      </p>
    </div>

    <div class="protocol-badges">
      {#each copy.protocols.names as proto}
        <span class="protocol-badge">{proto}</span>
      {/each}
    </div>

    <div class="code-block" id="homebrew">
      <span class="prompt">{copy.protocols.installTapPrompt}</span>
      <span class="command">brew tap lollipopkit/taps</span>
      <span class="prompt">{copy.protocols.installCaskPrompt}</span>
      <span class="command">brew install --cask mfuse</span>
    </div>
  </section>

  <section class="page-section" id="testimonials">
    <div class="section-head">
      <h2>{copy.testimonials.title}</h2>
    </div>

    <div class="testimonial-grid">
      {#each copy.testimonials.items as t}
        <article class="testimonial-card">
          <p class="quote">&ldquo;{t.quote}&rdquo;</p>
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
      <h2>{copy.cta.title}</h2>
      <p>
        {copy.cta.subtitle}
      </p>
      <div class="cta-actions">
        <a class="btn btn-secondary" href="#homebrew">{copy.cta.homebrewAction}</a>
        <a class="btn btn-primary" href="https://github.com/lollipopkit/mfuse/releases">{copy.cta.githubAction}</a>
      </div>
    </div>
  </section>

  <footer class="site-footer">
    <span>© 2026 MFuse</span>
    <div class="footer-links">
      <a href="#features">{copy.footer.features}</a>
      <a href="#protocols">{copy.footer.protocols}</a>
      <a href="https://github.com/lollipopkit/mfuse">GitHub</a>
      <a href="https://github.com/lollipopkit/mfuse/releases">{copy.footer.releases}</a>
    </div>
  </footer>
</main>
