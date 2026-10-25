// The web UI's languages: English, French, Spanish and Portuguese. Loaded first, in the <head> of every page (the
// server adds it to plugins' pages), it picks the language and writes the catalog's script tag, so the catalog runs
// before any other script. The English text is the key: `t("Sign in")`, `t("Restart {name}", { name })`,
// `tn("{n} line", "{n} lines", count)`; a text a catalog lacks stays English. Catalogs are i18n-fr.js, i18n-es.js and
// i18n-pt.js, `HomeswiftI18n.add("fr", {…})` around one JSON object; a plugin's page adds its own strings the same
// way from its own i18n.js. UITests.webStringsAreTranslated checks every t() and tn() literal is in each catalog.
(() => {
  "use strict";

  const languages = ["en", "fr", "es", "pt"];
  /// The language's own name, as the language picker shows it.
  const names = { en: "English", fr: "Français", es: "Español", pt: "Português" };
  /// The flags the language menus show beside the names.
  const flags = { en: "🇬🇧", fr: "🇫🇷", es: "🇪🇸", pt: "🇵🇹" };
  /// The region a language's dates and numbers take when the browser names none: Spain's Spanish, Portugal's Portuguese.
  const regions = { en: "en-US", fr: "fr-FR", es: "es-ES", pt: "pt-PT" };

  /// The user's choice, kept by common.js with their other preferences ("auto" follows the browser).
  function chosen() {
    try { return JSON.parse(localStorage.getItem("homeswift.preferences") || "{}").language || "auto"; } catch { return "auto"; }
  }
  const browser = (navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || "en"]).map((tag) => String(tag));
  /// "fr", "es", "pt" or "en" for a preference: a language of the four, or the browser's first one of them.
  function resolve(preference) {
    if (languages.includes(preference)) return preference;
    for (const tag of browser) {
      const primary = tag.toLowerCase().split("-")[0];
      if (languages.includes(primary)) return primary;
    }
    return "en";
  }
  const language = resolve(chosen());
  /// Dates and numbers: the browser's own variant of the language when it has one (fr-CA, en-GB), else the default region.
  const locale = browser.find((tag) => tag.toLowerCase().split("-")[0] === language && tag.includes("-")) || regions[language];
  document.documentElement.lang = locale;

  const catalog = Object.create(null);
  const plural = new Intl.PluralRules(locale);

  const fill = (text, vars) => vars ? text.replace(/\{(\w+)\}/g, (whole, name) => (name in vars && vars[name] != null ? String(vars[name]) : whole)) : text;
  const format = (vars) => {
    if (!vars) return vars;
    const out = {};
    for (const [key, value] of Object.entries(vars)) out[key] = typeof value === "number" ? value.toLocaleString(locale) : value;
    return out;
  };

  /// The text in the page's language, `{name}` filled from `vars` (numbers formatted for the locale). A key may end
  /// with a context in brackets, for a word English uses in two senses: "On [setting]" is "On" in English.
  function t(text, vars) {
    const translated = catalog[text];
    return fill(typeof translated === "string" && translated ? translated : text.replace(/ \[[\w ]+\]$/, ""), format(vars));
  }

  /// `one` or `other` by `count` as the page's language counts (French says "0 ligne"), `{n}` being the count.
  function tn(one, other, count, vars) {
    const key = plural.select(Number(count)) === "one" ? one : other;
    return t(key, { n: count, ...vars });
  }

  // Server text (an error from /api, a name from HomeKit's definitions) is translated when a catalog knows it: as
  // written, or as a key whose {placeholders} stand for its variable parts ("the image is too large: {0} MB at most").
  let patterns = null;
  const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  function message(text) {
    if (text == null || language === "en") return text;
    const value = String(text);
    if (typeof catalog[value] === "string" && catalog[value]) return catalog[value];
    if (!patterns) {
      patterns = [];
      for (const key of Object.keys(catalog)) {
        const parts = key.split(/\{\w+\}/);
        // A key of placeholders and little else would match anything.
        if (parts.length < 2 || parts.join("").length < 8) continue;
        const names = [...key.matchAll(/\{(\w+)\}/g)].map((match) => match[1]);
        patterns.push({ key, names, fixed: parts.join("").length, pattern: new RegExp(`^${parts.map(escape).join("(.+?)")}$`, "s") });
      }
      // The most specific first: "the Assistant did not answer: {0}: HTTP {1}: {2}" before "…: {0}", "{0} must be {1}" last.
      patterns.sort((a, b) => b.fixed - a.fixed);
    }
    for (const { key, names, pattern } of patterns) {
      const match = value.match(pattern);
      if (match) return fill(catalog[key], Object.fromEntries(names.map((name, index) => [name, match[index + 1]])));
    }
    return value;
  }

  /// A catalog's strings, for one language (`add("fr", {…})`) or several (`add({ fr: {…}, es: {…} })`, a plugin's).
  function add(code, strings) {
    if (typeof code === "object") { for (const [one, entries] of Object.entries(code)) add(one, entries); return; }
    if (code !== language) return;
    Object.assign(catalog, strings);
    patterns = null;
  }

  /// Static HTML: an element with `data-i18n` has its own text and its title, aria-label, placeholder and alt translated.
  function translate(root = document) {
    for (const node of root.querySelectorAll("[data-i18n]")) {
      for (const child of node.childNodes) {
        if (child.nodeType !== Node.TEXT_NODE || !child.nodeValue.trim()) continue;
        const [, before, text, after] = child.nodeValue.match(/^(\s*)([\s\S]*?)(\s*)$/);
        child.nodeValue = before + t(text.replace(/\s+/g, " ")) + after;
      }
      for (const attribute of ["title", "aria-label", "placeholder", "alt"]) {
        if (node.hasAttribute(attribute)) node.setAttribute(attribute, t(node.getAttribute(attribute)));
      }
    }
  }

  /// Before signing in, a language chosen from the sign-in page's flags: kept in this browser, and on the server once
  /// the user signs in (common.js's loadPreferences); the page opens again in it.
  function choose(code) {
    try {
      const kept = JSON.parse(localStorage.getItem("homeswift.preferences") || "{}");
      localStorage.setItem("homeswift.preferences", JSON.stringify({ ...kept, language: code }));
      localStorage.setItem("homeswift.language-chosen", code);
    } catch { return; }
    if (resolve(code) !== language) location.reload();
  }

  window.HomeswiftI18n = { languages, names, flags, language, locale, t, tn, message, add, translate, resolve, choose };

  // The catalog before the page's other scripts: a parser-inserted script written here runs before the next one.
  if (language !== "en" && document.readyState === "loading") {
    const own = new URL(document.currentScript.src);
    const catalogURL = new URL(`i18n-${language}.js`, own);
    catalogURL.search = own.search;
    document.write(`<script src="${catalogURL.pathname}${catalogURL.search}"><\/script>`);
  }
  if (language !== "en") {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", () => translate());
    else translate();
  }
})();
