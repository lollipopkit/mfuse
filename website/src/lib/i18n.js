import { baseLocale, locales as generatedLocales } from '../i18n/i18n-util'

export const defaultLocale = baseLocale

/** @type {{ code: import('../i18n/i18n-types').Locales, label: string }[]} */
const declaredLocales = [
  { code: 'en', label: 'English' },
  { code: 'zh-CN', label: '简体中文' },
]

export const locales = declaredLocales.filter((locale) => generatedLocales.includes(locale.code))

export const localeStorageKey = 'mfuse.website.locale'

/**
 * Narrows an arbitrary string to a locale the generated bundle actually has.
 *
 * @param {string} locale
 * @returns {locale is import('../i18n/i18n-types').Locales}
 */
function isGeneratedLocale(locale) {
  return /** @type {readonly string[]} */ (generatedLocales).includes(locale)
}

/**
 * The locale a value asks for, or `undefined` when it asks for one this bundle does not
 * have. A tag it can be resolved from — `zh-TW`, `en-GB` — is resolved, not rejected.
 *
 * @param {string | null | undefined} locale
 * @returns {import('../i18n/i18n-types').Locales | undefined}
 */
export function resolveLocale(locale) {
  if (!locale) return undefined
  if (isGeneratedLocale(locale)) return locale

  const lowerLocale = locale.toLowerCase()
  if (lowerLocale.startsWith('zh')) return 'zh-CN'
  if (lowerLocale.startsWith('en')) return 'en'

  return undefined
}

/**
 * @param {string | null | undefined} locale
 * @returns {import('../i18n/i18n-types').Locales}
 */
export function normalizeLocale(locale) {
  return resolveLocale(locale) ?? defaultLocale
}

/**
 * The first source that names a locale this bundle has: the query string, then what was
 * stored, then the browser.
 *
 * A value none of them can be resolved from is skipped rather than answered with the
 * default — a bookmarked `?lang=fr`, or `fr` left in storage by an earlier build, would
 * otherwise stand in for a preference and keep a browser set to a supported locale from
 * being read at all.
 */
export function getInitialLocale() {
  const params = new URLSearchParams(window.location.search)
  const queryLocale = resolveLocale(params.get('lang'))
  if (queryLocale) return queryLocale

  const storedLocale = resolveLocale(localStorage.getItem(localeStorageKey))
  if (storedLocale) return storedLocale

  return normalizeLocale(navigator.languages?.[0] || navigator.language)
}

/** @param {string | null | undefined} locale */
export function syncLocaleToUrl(locale) {
  const url = new URL(window.location.href)
  url.searchParams.set('lang', normalizeLocale(locale))
  window.history.replaceState({}, '', url)
}
