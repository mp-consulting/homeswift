// The website's languages: English, French, Spanish (Spain) and Portuguese (Portugal), the web UI's four, with the
// same conventions as its Web/i18n.js: the English text is the key (`t("Allow")`, `t("Heat to {t}", { t })`,
// `tn("{n} entry", "{n} entries", count)`), a text a catalog lacks stays English, and a catalog is
// `HomeswiftI18n.add("fr", {…})` in i18n-fr.js, i18n-es.js or i18n-pt.js, one for the whole site.
//
// Loaded in the <head>, not deferred: it picks the language (`?lang=`, then the visitor's last choice, then the
// browser's), writes the catalog's script tag so it runs before the page's own scripts, and translates the static
// HTML before they run. Until then the page stays hidden, so English never flashes before French.
(() => {
  'use strict';

  const languages = ['en', 'fr', 'es', 'pt'];
  const names = { en: 'English', fr: 'Français', es: 'Español', pt: 'Português' };
  const regions = { en: 'en-US', fr: 'fr-FR', es: 'es-ES', pt: 'pt-PT' };
  const key = 'homeswift.site.language';

  const stored = () => { try { return localStorage.getItem(key); } catch { return null; } };
  const browser = (navigator.languages?.length ? navigator.languages : [navigator.language || 'en']).map(String);
  function resolve() {
    const asked = new URLSearchParams(location.search).get('lang');
    if (languages.includes(asked)) { try { localStorage.setItem(key, asked); } catch {} return asked; }
    if (languages.includes(stored())) return stored();
    for (const tag of browser) { const primary = tag.toLowerCase().split('-')[0]; if (languages.includes(primary)) return primary; }
    return 'en';
  }
  const language = resolve();
  // Portuguese is Portugal's and Spanish is Spain's, whatever the browser's variant: the catalogs are written for them.
  const locale = language === 'en' ? (browser.find((tag) => /^en-/i.test(tag)) || regions.en) : regions[language];
  document.documentElement.lang = locale;

  const catalog = Object.create(null);
  const plural = new Intl.PluralRules(locale);
  const fill = (text, vars) => vars ? text.replace(/\{(\w+)\}/g, (whole, name) => (name in vars && vars[name] != null ? String(vars[name]) : whole)) : text;
  const format = (vars) => vars && Object.fromEntries(Object.entries(vars).map(([k, v]) => [k, typeof v === 'number' ? v.toLocaleString(locale) : v]));

  /// The text in the page's language, `{name}` filled from `vars` (numbers formatted for the locale).
  function t(text, vars) {
    const translated = catalog[text];
    return fill(typeof translated === 'string' && translated ? translated : text, format(vars));
  }
  /// `one` or `other` by `count` as the page's language counts, `{n}` being the count.
  function tn(one, other, count, vars) {
    return t(plural.select(Number(count)) === 'one' ? one : other, { n: count, ...vars });
  }
  /// Numbers and percentages as the locale writes them: 19,5 and 80 % in French, 19.5 and 80% in English.
  const number = (value, digits = 1) => value.toLocaleString(locale, { maximumFractionDigits: digits });
  const percent = (value) => (value / 100).toLocaleString(locale, { style: 'percent' });

  function add(code, strings) {
    if (typeof code === 'object') { for (const [one, entries] of Object.entries(code)) add(one, entries); return; }
    if (code === language) Object.assign(catalog, strings);
  }

  /// The static HTML. `data-i18n`: the element's own text nodes, and its title, aria-label, placeholder, alt and
  /// content. `data-i18n-html`: the whole inner HTML is the key, whitespace collapsed (exact inside <pre>), for copy
  /// with inline markup; a translation keeps the same tags.
  const htmlKey = (el) => el.closest('pre') ? el.innerHTML : el.innerHTML.replace(/\s+/g, ' ').trim();
  function translate(root = document) {
    if (language === 'en') return;
    for (const node of root.querySelectorAll('[data-i18n]')) {
      for (const child of node.childNodes) {
        if (child.nodeType !== Node.TEXT_NODE || !child.nodeValue.trim()) continue;
        const [, before, text, after] = child.nodeValue.match(/^(\s*)([\s\S]*?)(\s*)$/);
        child.nodeValue = before + t(text.replace(/\s+/g, ' ')) + after;
      }
      for (const attribute of ['title', 'aria-label', 'placeholder', 'alt', 'content']) {
        if (node.hasAttribute(attribute)) node.setAttribute(attribute, t(node.getAttribute(attribute)));
      }
    }
    for (const node of root.querySelectorAll('[data-i18n-html]')) {
      const translated = catalog[htmlKey(node)];
      if (typeof translated === 'string' && translated) node.innerHTML = translated;
    }
  }

  /// Another language: remembered, and the page reloaded with it in its address so the link can be shared.
  function choose(code) {
    if (!languages.includes(code)) return;
    try { localStorage.setItem(key, code); } catch {}
    const url = new URL(location.href);
    url.searchParams.set('lang', code);
    location.assign(url);
  }

  window.HomeswiftI18n = { languages, names, language, locale, t, tn, number, percent, add, translate, choose, htmlKey };

  if (language === 'en') return;
  const root = document.documentElement;
  root.classList.add('i18n-pending');
  const reveal = () => root.classList.remove('i18n-pending');
  setTimeout(reveal, 1500); // a catalog that fails to load leaves the page in English rather than blank
  // The catalog takes this script's own query (?v=<commit>, added at deploy), so a cache never pairs them across deploys.
  const version = document.currentScript ? new URL(document.currentScript.src).search : '';
  if (document.readyState === 'loading') document.write(`<script src="i18n-${language}.js${version}"><\/script>`);
  // 'interactive' comes after parsing and before deferred scripts run, so they read translated text.
  const done = () => { translate(); reveal(); };
  if (document.readyState === 'loading') document.addEventListener('readystatechange', done, { once: true });
  else done();
})();
