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
 * @param {string | null | undefined} locale
 * @returns {import('../i18n/i18n-types').Locales}
 */
export function normalizeLocale(locale) {
  if (!locale) return defaultLocale
  if (isGeneratedLocale(locale)) return locale

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

/** @param {string | null | undefined} locale */
export function syncLocaleToUrl(locale) {
  const url = new URL(window.location.href)
  url.searchParams.set('lang', normalizeLocale(locale))
  window.history.replaceState({}, '', url)
}
