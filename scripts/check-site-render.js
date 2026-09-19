#!/usr/bin/env node
// Renders assets/site.js against the repository's real catalogues and asserts
// what a reader sees on both hosts: the schematic catalogue and the plugin
// section. This is the reproduction for two defects that reached a pull request
// on 2026-09-19 - a catalogue key rename the script did not follow (the page
// then rendered "No schematics published yet." instead of erroring) and an
// optional plugin fetch that gated the whole catalogue (a request that stalled
// rather than failed left the page blank).
//
// No dependencies. Run from the repository root:  node scripts/check-site-render.js

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const ROOT = path.resolve(__dirname, "..");
const CATALOG = ".agent-schematics/marketplace.json";
const PLUGINS = ".claude-plugin/marketplace.json";

// The predicates below must match renderCatalog / renderPluginSection in
// assets/site.js. If the site's filter changes, change it here too - the point
// of this file is to fail when those two drift apart.
const isCatalogEntry = (e) => e.category !== "authoring" && !!e.featured;
const isPluginEntry = (e) => e.category === "authoring";

function el(tag) {
  return {
    tagName: (tag || "div").toUpperCase(),
    className: "", textContent: "", style: {}, children: [], _html: "",
    appendChild(c) { this.children.push(c); return c; },
    removeChild(c) { this.children = this.children.filter((x) => x !== c); return c; },
    setAttribute() {}, addEventListener() {},
    get innerHTML() { return this._html; },
    set innerHTML(v) { this._html = v; if (v === "") this.children = []; },
    _all(out) { for (const c of this.children) { out.push(c); c._all(out); } return out; },
    querySelectorAll(sel) {
      const cls = String(sel).split(".").pop().replace(/^article\s*/, "");
      return this._all([]).filter((n) => (n.className || "").split(/\s+/).includes(cls));
    },
    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; },
  };
}

// `stall` makes the OPTIONAL plugin request hang rather than fail - the shape
// that left the catalogue blank before the fetch was decoupled from the render.
function render(stall) {
  const hosts = {};
  for (const id of ["catalog-list", "plugin-list", "stat-count", "toast"]) hosts[id] = el("div");
  const sandbox = {
    document: {
      readyState: "complete", createElement: el, addEventListener() {}, body: el("body"),
      getElementById: (id) => hosts[id] || null,
    },
    fetch: (url) => {
      // The page builds its URLs from RAW_BASE, a raw.githubusercontent URL.
      // Map by the known repo-relative path at the end rather than by prefix,
      // so this keeps working if RAW_BASE changes.
      const rel = [CATALOG, PLUGINS].find((p) => String(url).endsWith(p));
      if (!rel) return Promise.resolve({ ok: false, status: 404, text: () => Promise.resolve("") });
      if (stall && rel === PLUGINS) return new Promise(() => {});
      const f = path.join(ROOT, rel);
      if (!fs.existsSync(f)) return Promise.resolve({ ok: false, status: 404, text: () => Promise.resolve("") });
      return Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve(fs.readFileSync(f, "utf8")) });
    },
    navigator: {}, console, setTimeout, clearTimeout, Promise, Error, JSON,
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(ROOT, "assets/site.js"), "utf8"), sandbox,
    { filename: "assets/site.js" });
  return new Promise((resolve) => setTimeout(() => resolve({
    schematicCards: hosts["catalog-list"].querySelectorAll("article.catalog-card").length,
    pluginCards: hosts["plugin-list"].querySelectorAll("article.catalog-card").length,
    emptyStateShown: hosts["catalog-list"].querySelector(".catalog-empty") !== null,
    heroStat: hosts["stat-count"].textContent,
  }), 900));
}

// Expected values are derived from the catalogues, so adding a schematic or a
// plugin needs no edit here.
function expected() {
  const catalog = JSON.parse(fs.readFileSync(path.join(ROOT, CATALOG), "utf8"));
  if (!Array.isArray(catalog.schematics)) {
    throw new Error(`${CATALOG} has no "schematics" array - the site reads that key, ` +
      `and a rename silently renders nothing`);
  }
  const plugins = JSON.parse(fs.readFileSync(path.join(ROOT, PLUGINS), "utf8"));
  const featured = catalog.schematics.filter(isCatalogEntry).length;
  const authoring = (plugins.plugins || []).filter(isPluginEntry).length;
  if (featured === 0) throw new Error(`${CATALOG} has no featured entries - nothing would render`);
  if (authoring !== 1) throw new Error(`${PLUGINS} should hold exactly one authoring plugin, found ${authoring}`);
  return { featured, authoring, total: catalog.schematics.length };
}

const failures = [];
function check(label, got, want) {
  const ok = got === want;
  if (!ok) failures.push(`${label}: got ${got}, want ${want}`);
  console.log(`  ${ok ? "ok  " : "FAIL"} ${label} = ${got}`);
}

(async () => {
  const { featured, authoring, total } = expected();
  console.log(`catalogues: ${total} schematic entries (${featured} featured), ${authoring} authoring plugin`);

  console.log("\nplugin marketplace available:");
  const normal = await render(false);
  check("schematic cards", normal.schematicCards, featured);
  check("plugin cards", normal.pluginCards, authoring);
  check("hero count", normal.heroStat, String(featured));
  check("empty state shown", normal.emptyStateShown, false);

  console.log("\nplugin marketplace STALLS - the catalogue must still render:");
  const stalled = await render(true);
  check("schematic cards", stalled.schematicCards, featured);
  check("hero count", stalled.heroStat, String(featured));
  check("plugin cards", stalled.pluginCards, 0);

  if (failures.length) {
    console.error(`\nFAILED (${failures.length}):`);
    for (const f of failures) console.error(`  - ${f}`);
    process.exit(1);
  }
  console.log("\nall render checks passed");
})().catch((err) => { console.error(`check-site-render: ${err.message}`); process.exit(2); });
