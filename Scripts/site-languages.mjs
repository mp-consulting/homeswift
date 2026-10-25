// Writes the home page of homeswift.dev in French, Spanish and Portuguese: site/fr/index.html, site/es/index.html and
// site/pt/index.html, from site/index.html and the catalogs site/i18n-fr.js, i18n-es.js and i18n-pt.js. Static pages,
// so search engines read each language; the demo's own strings still come from the catalogs at run time (i18n.js).
//
//   node Scripts/site-languages.mjs           # write the three pages
//   node Scripts/site-languages.mjs --check   # exit 1 when a page is stale or a text has no translation
//
// In site/index.html, an element with data-i18n has its own text and its title, aria-label, placeholder, alt and
// content attributes translated; with data-i18n-html, its whole inner HTML (whitespace collapsed, exact inside <pre>)
// is the key, and a translation keeps the same tags. The English text is the key, as in the web UI's catalogs.
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const site = join(dirname(fileURLToPath(import.meta.url)), "..", "site");
const check = process.argv.includes("--check");
const languages = { fr: { locale: "fr_FR" }, es: { locale: "es_ES" }, pt: { locale: "pt_PT" } };
const origin = "https://homeswift.dev";

const english = readFileSync(join(site, "index.html"), "utf8");

function catalog(code) {
  let strings = null;
  vm.runInNewContext(readFileSync(join(site, `i18n-${code}.js`), "utf8"), { HomeswiftI18n: { add: (c, s) => { if (c === code) strings = s; } } });
  if (!strings) throw new Error(`i18n-${code}.js adds no "${code}" strings`);
  return strings;
}

const entities = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };
const decode = (text) => text.replace(/&(#x[\da-f]+|#\d+|\w+);/gi, (whole, name) =>
  name[0] === "#" ? String.fromCodePoint(name[1].toLowerCase() === "x" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10)) : entities[name] ?? whole);
const escapeText = (text) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const escapeAttribute = (text) => escapeText(text).replace(/"/g, "&quot;");
// As i18n.js does at run time: whitespace, non-breaking spaces included, collapsed.
const collapse = (text) => text.replace(/\s+/g, " ").trim();

const voids = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]);

// The page's tags, in order, with where each starts and ends; comments and the inside of <script> are skipped.
function tags(html) {
  const out = [];
  const pattern = /<!--[\s\S]*?-->|<script\b[^>]*>[\s\S]*?<\/script>|<(\/?)([a-zA-Z][\w-]*)((?:"[^"]*"|'[^']*'|[^>"'])*)>/g;
  for (let m; (m = pattern.exec(html));) {
    if (!m[2]) continue;
    const name = m[2].toLowerCase();
    out.push({ start: m.index, end: pattern.lastIndex, name, closing: m[1] === "/", attributes: m[3], single: voids.has(name) || /\/\s*$/.test(m[3]) });
  }
  return out;
}

function translatePage(code) {
  const strings = catalog(code);
  const missing = new Set();
  const t = (key) => {
    const value = strings[key];
    if (typeof value === "string" && value) return value;
    missing.add(key);
    return key;
  };
  const list = tags(english);
  const edits = [];

  list.forEach((tag, index) => {
    if (tag.closing || !/\sdata-i18n(-html)?\b/.test(tag.attributes)) return;
    const html = /\sdata-i18n-html\b/.test(tag.attributes);

    // Attributes, on the opening tag.
    if (!html) {
      for (const attribute of ["title", "aria-label", "placeholder", "alt", "content"]) {
        const m = new RegExp(`(\\s${attribute}=")([^"]*)(")`).exec(tag.attributes);
        if (!m) continue;
        const from = tag.start + 1 + tag.name.length + m.index + m[1].length;
        edits.push([from, from + m[2].length, escapeAttribute(t(decode(m[2])))]);
      }
    }
    if (tag.single) return;

    // The element's end, and its own text: what lies between tags at its top level.
    let depth = 0, close = null;
    const segments = [];
    let cursor = tag.end;
    for (let i = index + 1; i < list.length; i++) {
      const inner = list[i];
      if (depth === 0 && inner.start > cursor) segments.push([cursor, inner.start]);
      if (inner.closing) {
        if (depth === 0) { if (inner.name !== tag.name) throw new Error(`<${tag.name}> at ${tag.start} closed by </${inner.name}>`); close = inner; break; }
        depth--;
      } else if (!inner.single) depth++;
      cursor = inner.end;
    }
    if (!close) throw new Error(`<${tag.name}> at ${tag.start} is never closed`);

    if (html) {
      const inner = english.slice(tag.end, close.start);
      const key = english.slice(0, tag.start).lastIndexOf("<pre") > english.slice(0, tag.start).lastIndexOf("</pre>") || tag.name === "pre" ? inner : collapse(inner);
      edits.push([tag.end, close.start, t(key)]);
      return;
    }
    for (const [from, to] of segments) {
      const raw = english.slice(from, to);
      if (!raw.trim()) continue;
      const [, before, , after] = raw.match(/^(\s*)([\s\S]*?)(\s*)$/);
      edits.push([from, to, before + escapeText(t(collapse(decode(raw)))) + after]);
    }
  });

  let page = english;
  for (const [from, to, text] of edits.sort((a, b) => b[0] - a[0])) page = page.slice(0, from) + text + page.slice(to);

  // The language, the page's own address, and its assets one directory up; links to other pages stay relative, so
  // privacy.html and bridge.html are this language's.
  const replaceOnce = (from, to) => {
    if (!page.includes(from)) throw new Error(`site/index.html no longer has ${from}`);
    page = page.replace(from, to);
  };
  replaceOnce('<html lang="en">', `<html lang="${code}">`);
  replaceOnce(`<link rel="canonical" href="${origin}/">`, `<link rel="canonical" href="${origin}/${code}/">`);
  replaceOnce(`<meta property="og:url" content="${origin}/">`, `<meta property="og:url" content="${origin}/${code}/">`);
  replaceOnce('<meta property="og:locale" content="en_US">', `<meta property="og:locale" content="${languages[code].locale}">`);
  page = page.replace(/(<script type="application\/ld\+json">)([\s\S]*?)(<\/script>)/, (whole, open, json, end) => {
    const data = JSON.parse(json);
    data.url = `${origin}/${code}/`;
    data.inLanguage = code;
    data.description = t(data.description);
    return `${open}\n${JSON.stringify(data)}\n${end}`;
  });
  page = page.replace(/(\s(?:href|src)=")(?![a-z]+:|\/|#)([^"]+\.(?:css|js|svg|png|ico|webmanifest))(")/g, "$1../$2$3");
  page = page.replaceAll('href="/design/"', `href="/design/?lang=${code}"`);
  // The language links: this page is the current one, in the footer and in the bar's picker.
  page = page.replace(/ aria-current="page"/g, "").replace(new RegExp(`(<a href="/${code}/" hreflang="${code}"[^>]*?)>`), '$1 aria-current="page">');
  page = page.replace(/ selected>/g, ">").replace(`<option value="/${code}/" lang="${code}">`, `<option value="/${code}/" lang="${code}" selected>`);
  // The note for editors, about this copy.
  page = page.replace(/<!-- The home page:[\s\S]*?-->/, `<!-- Generated by Scripts/site-languages.mjs from ../index.html and ../i18n-${code}.js: edit those, then run it. -->`);
  return { page, missing };
}

let failed = false;
for (const code of Object.keys(languages)) {
  const { page, missing } = translatePage(code);
  const file = join(site, code, "index.html");
  if (missing.size) {
    failed = true;
    console.error(`i18n-${code}.js has no translation for:\n${[...missing].map((key) => `  ${JSON.stringify(key)}`).join("\n")}`);
  }
  if (check) {
    if (!existsSync(file) || readFileSync(file, "utf8") !== page) { failed = true; console.error(`site/${code}/index.html is stale: run node Scripts/site-languages.mjs`); }
  } else if (!missing.size) {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, page);
    console.log(`site/${code}/index.html`);
  }
}
process.exit(failed ? 1 : 0);
