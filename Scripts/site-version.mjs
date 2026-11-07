// Keeps the released version shown to people in step with PluginHost.version: the bridge page's "vX.Y.Z" and its
// Package.swift snippet (in English, French, Spanish and Portuguese), and the README's Package.swift snippet.
//
//   node Scripts/site-version.mjs           # write the version into them
//   node Scripts/site-version.mjs --check   # exit 1 when one shows another version (CI's website job)
import { readFileSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const check = process.argv.includes("--check");

const host = readFileSync(join(root, "Sources/HomeswiftPlugin/PluginHost.swift"), "utf8");
const version = host.match(/public static let version = "(\d+\.\d+\.\d+)"/)?.[1];
if (!version) throw new Error("PluginHost.swift has no version");

// Each file, and the places a version sits in it: the pattern's first group is kept, the version follows it.
const bridge = [
  /(<p class="meta"><span>v)\d+\.\d+\.\d+/g,
  /(from: <span class="s">")\d+\.\d+\.\d+/g,
];
const files = {
  "site/bridge.html": bridge,
  "site/fr/bridge.html": bridge,
  "site/es/bridge.html": bridge,
  "site/pt/bridge.html": bridge,
  "README.md": [/(\.package\(url: "https:\/\/github\.com\/mp-consulting\/homeswift\.git", from: ")\d+\.\d+\.\d+/g],
};

let stale = false;
for (const [file, patterns] of Object.entries(files)) {
  const path = join(root, file);
  const before = readFileSync(path, "utf8");
  let after = before;
  for (const pattern of patterns) {
    if (before.search(pattern) === -1) throw new Error(`${file} no longer has ${pattern}: update Scripts/site-version.mjs`);
    after = after.replace(pattern, `$1${version}`);
  }
  if (after === before) continue;
  if (check) { console.error(`${file} shows another version than ${version}: run node Scripts/site-version.mjs`); stale = true; }
  else { writeFileSync(path, after); console.log(`${file}: ${version}`); }
}
if (stale) process.exit(1);
