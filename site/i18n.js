// The website's languages: English, French, Spanish (Spain) and Portuguese (Portugal), the web UI's four, with the
// same conventions as its Web/i18n.js: the English text is the key (`t("Allow")`, `t("Heat to {target}", { target })`,
// `tn("{n} entry", "{n} entries", count)`), a text a catalog lacks stays English, and a catalog is
// `HomeswiftI18n.add("fr", {…})` in i18n-fr.js, i18n-es.js or i18n-pt.js, one for the whole site.
//
// Each language is a page of its own (fr/, es/, pt/; Scripts/site-languages.mjs writes them from the English page and
// the catalogs), so the page's <html lang> is the language. This script, loaded in the <head> and not deferred, writes
// the catalog's script tag so it runs before the page's own scripts, which use t() for the text they write.
(() => {
  'use strict';

  const languages = ['en', 'fr', 'es', 'pt'];
  const regions = { en: 'en-US', fr: 'fr-FR', es: 'es-ES', pt: 'pt-PT' };
  const declared = (document.documentElement.lang || 'en').toLowerCase().split('-')[0];
  const language = languages.includes(declared) ? declared : 'en';
  // Portuguese is Portugal's and Spanish is Spain's: the catalogs are written for them.
  const locale = regions[language];

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
    if (code === language) Object.assign(catalog, strings);
  }

  window.HomeswiftI18n = { languages, language, locale, t, tn, number, percent, add };

  if (language === 'en' || document.readyState !== 'loading') return;
  // The catalog sits beside this script (the pages in fr/ load ../i18n.js) and takes its query, ?v=<commit> added at
  // deploy, so a cache never pairs them across deploys.
  const self = document.currentScript ? new URL(document.currentScript.src) : new URL('i18n.js', location.href);
  const catalogURL = new URL(`i18n-${language}.js`, self);
  catalogURL.search = self.search;
  document.write(`<script src="${catalogURL.pathname}${catalogURL.search}"><\/script>`);
})();
