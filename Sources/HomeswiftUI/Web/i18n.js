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

  /// The user's Preferences as common.js keeps them in this browser (the server's, last seen).
  const kept = (() => { try { return JSON.parse(localStorage.getItem("homeswift.preferences") || "{}") || {}; } catch { return {}; } })();
  /// The user's choice of language ("auto" follows the browser).
  const chosen = () => kept.language || "auto";
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

  // ---- Regional Formats and Home Time (GLOSSARY.md) ----------------------------------------------------------------
  // Each is "auto" unless the user picked one on the Appearance page: the Language and the browser's region decide.
  const choice = (key, allowed) => (allowed.includes(kept[key]) ? kept[key] : "auto");
  const timeFormat = choice("timeFormat", ["12", "24"]);
  const dateFormat = choice("dateFormat", ["dmy", "mdy", "ymd"]);
  const numberFormat = choice("numberFormat", ["point", "comma", "space"]);
  const firstWeekdayChoice = choice("firstWeekday", ["mon", "sat", "sun"]);
  /// Numbers: the locale whose separators the user chose (1,234.5, 1.234,5, 1 234,5), else the page's.
  const numberLocale = { point: "en-US", comma: "de-DE", space: "fr-FR" }[numberFormat] || locale;
  const deviceTimeZone = new Intl.DateTimeFormat().resolvedOptions().timeZone;
  const knownZone = (zone) => { try { return typeof zone === "string" && zone && new Intl.DateTimeFormat("en", { timeZone: zone }) && true; } catch { return false; } };
  /// Home Time, the bridge's zone, unless the user chose the device's (rules are always written in Home Time).
  const homeTimeZone = knownZone(kept.homeTimeZone) ? kept.homeTimeZone : deviceTimeZone;
  const timeZone = kept.timeZone === "device" ? deviceTimeZone : homeTimeZone;
  /// The week's first day, 1 (Monday) to 7 (Sunday), as Intl.Locale's weekInfo counts.
  const firstWeekday = { mon: 1, sat: 6, sun: 7 }[firstWeekdayChoice] || (() => {
    try { const one = new Intl.Locale(locale); return (one.getWeekInfo?.() ?? one.weekInfo)?.firstDay ?? 1; } catch { return 1; }
  })();

  /// A date's numeric day, month and year in the order the user chose; text months ("7 Nov") stay the language's.
  const orders = { dmy: ["day", "month", "year"], mdy: ["month", "day", "year"], ymd: ["year", "month", "day"] };
  function reorder(parts) {
    if (dateFormat === "auto") return parts;
    const places = parts.flatMap((part, index) => (["day", "month", "year"].includes(part.type) && /^\d+$/.test(part.value) ? [index] : []));
    if (places.length < 2) return parts;
    for (let index = places[0]; index <= places[places.length - 1]; index++) {
      if (!places.includes(index) && parts[index].type !== "literal") return parts;
    }
    const present = places.map((index) => parts[index]);
    const ordered = orders[dateFormat].map((type) => present.find((part) => part.type === type)).filter(Boolean);
    const out = parts.slice();
    places.forEach((index, at) => { out[index] = ordered[at]; });
    // Year first is written with hyphens, as ISO 8601 does.
    if (dateFormat === "ymd") for (let index = places[0] + 1; index < places[places.length - 1]; index++) if (out[index].type === "literal") out[index] = { type: "literal", value: "-" };
    return out;
  }

  const dateFormats = new Map();
  /// An Intl.DateTimeFormat in the page's language with the user's Regional Formats, in Home Time (or the device's zone,
  /// as the user chose) unless `options` names a zone. Use it, `formatDate` and `zoned` for every date the pages show.
  function dateTimeFormat(options = {}) {
    const key = JSON.stringify(options);
    if (dateFormats.has(key)) return dateFormats.get(key);
    const settled = { ...options };
    if (!("timeZone" in settled)) settled.timeZone = timeZone;
    // A chosen order with the four-digit year: the short style's two digits read badly year first.
    if (dateFormat !== "auto" && settled.dateStyle === "short") {
      delete settled.dateStyle;
      Object.assign(settled, { year: "numeric", month: "2-digit", day: "2-digit" });
      if (settled.timeStyle) { Object.assign(settled, { hour: "numeric", minute: "2-digit", ...(settled.timeStyle === "short" ? {} : { second: "2-digit" }) }); delete settled.timeStyle; }
    }
    if (timeFormat !== "auto" && ("hour" in settled || "timeStyle" in settled)) {
      delete settled.hour12;
      settled.hourCycle = timeFormat === "12" ? "h12" : "h23";
      // "5:39 pm", not "05:39 pm": a 12-hour clock writes its hour without a leading zero.
      if (timeFormat === "12" && settled.hour === "2-digit") settled.hour = "numeric";
    }
    const format = new Intl.DateTimeFormat(locale, settled);
    const join = (parts) => parts.map((part) => part.value).join("");
    const made = dateFormat === "auto" ? format : {
      format: (date) => join(reorder(format.formatToParts(date))),
      formatToParts: (date) => reorder(format.formatToParts(date)),
      formatRange: (from, to) => {
        const [a, b] = [join(reorder(format.formatToParts(from))), join(reorder(format.formatToParts(to)))];
        return a === b ? a : `${a} – ${b}`;
      },
      resolvedOptions: () => format.resolvedOptions(),
    };
    dateFormats.set(key, made);
    return made;
  }
  /// A date (a Date, milliseconds or an ISO 8601 string) as `dateTimeFormat(options)` writes it.
  const formatDate = (date, options) => dateTimeFormat(options).format(date instanceof Date ? date : new Date(date));

  // Calendar arithmetic in the zone the pages show: what Date's getHours() and new Date(y, m, d) do in the device's.
  const fields = new Intl.DateTimeFormat("en-US", { timeZone, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric",
    hour: "numeric", minute: "numeric", second: "numeric", weekday: "short" });
  const weekdays = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  const fieldNames = { hour: "hours", minute: "minutes", second: "seconds" };
  /// The zone is the device's (most users): Date's own local fields are the answer, without Intl.
  const local = timeZone === deviceTimeZone;
  /// A moment's wall-clock fields in that zone: `year`, `month` (0 to 11, as Date's), `day`, `hours`, `minutes`,
  /// `seconds` and `weekday` (0 for Sunday).
  function zoned(date) {
    const moment = date instanceof Date ? date : new Date(date);
    if (local) {
      return { year: moment.getFullYear(), month: moment.getMonth(), day: moment.getDate(), hours: moment.getHours(),
        minutes: moment.getMinutes(), seconds: moment.getSeconds(), weekday: moment.getDay() };
    }
    const out = {};
    for (const part of fields.formatToParts(moment)) {
      if (part.type === "weekday") out.weekday = weekdays[part.value];
      else if (part.type !== "literal") out[fieldNames[part.type] || part.type] = Number(part.value);
    }
    out.month -= 1;
    return out;
  }
  /// The moment a wall-clock time is in that zone, as `new Date(year, month, day, hours, minutes, seconds)` would be in
  /// the device's (fields may overflow: day 0 is the month before's last). A time a clock change skips moves forward.
  function zonedDate(year, month, day = 1, hours = 0, minutes = 0, seconds = 0) {
    if (local) return new Date(year, month, day, hours, minutes, seconds);
    const wall = Date.UTC(year, month, day, hours, minutes, seconds);
    const offset = (moment) => {
      const at = zoned(new Date(moment));
      return Date.UTC(at.year, at.month, at.day, at.hours, at.minutes, at.seconds) - moment;
    };
    let moment = wall - offset(wall);
    const again = wall - offset(moment);
    if (again !== moment) moment = Math.max(moment, again);
    return new Date(moment);
  }
  /// Midnight of the day `date` is in, in that zone.
  const startOfDay = (date) => { const at = zoned(date); return zonedDate(at.year, at.month, at.day); };
  /// For the range picker's calendar, written with Date's local fields: a Date whose device-local fields are the zone's
  /// wall clock at `date` (format it with `timeZone: deviceTimeZone`; `zonedDate` turns its fields back into a moment).
  const wallClock = (date) => { const at = zoned(date); return new Date(at.year, at.month, at.day, at.hours, at.minutes, at.seconds); };

  /// What the page opened with, resolved: a choice, its default, or the zone it took for Home Time. `differs` names the
  /// first preference the user now has otherwise (null when none): the page must open again to take it.
  const opened = { timeFormat, dateFormat, numberFormat, firstWeekday: firstWeekdayChoice, timeZone: kept.timeZone === "device" ? "device" : "home" };
  function differs(preferences) {
    if (resolve(preferences.language) !== language) return "language";
    const key = Object.keys(opened).find((one) => preferences[one] != null && preferences[one] !== opened[one]);
    if (key) return key;
    // Home Time moved on the bridge; a zone this browser cannot use (i18n.js takes the device's then) is no change.
    const zone = preferences.homeTimeZone;
    return zone != null && zone !== kept.homeTimeZone && knownZone(zone) && zone !== homeTimeZone ? "homeTimeZone" : null;
  }

  const catalog = Object.create(null);
  const plural = new Intl.PluralRules(locale);

  const fill = (text, vars) => vars ? text.replace(/\{(\w+)\}/g, (whole, name) => (name in vars && vars[name] != null ? String(vars[name]) : whole)) : text;
  const format = (vars) => {
    if (!vars) return vars;
    const out = {};
    for (const [key, value] of Object.entries(vars)) out[key] = typeof value === "number" ? value.toLocaleString(numberLocale) : value;
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

  window.HomeswiftI18n = {
    languages, names, flags, language, locale, t, tn, message, add, translate, resolve, choose,
    numberLocale, timeZone, homeTimeZone, deviceTimeZone, firstWeekday, dateTimeFormat, formatDate, zoned, zonedDate, startOfDay, wallClock, differs,
  };

  // The catalog before the page's other scripts: a parser-inserted script written here runs before the next one.
  if (language !== "en" && document.readyState === "loading") {
    const own = new URL(document.currentScript.src);
    const catalogURL = new URL(`i18n-${language}.js`, own);
    catalogURL.search = own.search;
    // The URL as an attribute value: a URL encodes these already, and escaping says so.
    const attribute = (text) => text.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
    document.write(`<script src="${attribute(catalogURL.pathname + catalogURL.search)}"><\/script>`);
  }
  if (language !== "en") {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", () => translate());
    else translate();
  }
})();
