#!/usr/bin/env node
// Renders assets/site.js against the repository's real catalogues and asserts
// what a reader sees on both hosts: the schematic catalogue and the plugin
// section. This is the reproduction for two defects that reached a pull request
// on 2026-09-19 - a catalogue key rename the script did not follow (the page
// then rendered "No schematics published yet." instead of erroring) and an
// optional plugin fetch that gated the whole catalogue (a request that stalled
// rather than failed left the page blank).
//
// It also holds the page to its data source: both files are fetched from the
// raw base the page builds, and a request to anything else fails the check
// rather than reading a local file the browser would not have got. The render
// is sampled once the page's requests have settled, not after a fixed delay.
//
// No dependencies. Run from the repository root:  node scripts/check-site-render.js

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const ROOT = path.resolve(__dirname, "..");
const CATALOG = ".agent-schematics/marketplace.json";
const PLUGINS = ".claude-plugin/marketplace.json";
// The page reads both files from this base at load time, so the check asserts
// the base and not just the path: a base pointing at another host, repository
// or branch 404s in a browser and leaves the page in its load-error state,
// while a suffix-only match would read a local file and pass anyway.
const RAW_BASE = "https://raw.githubusercontent.com/cameri/schematics/main/";

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

// Waits until every request the page made has settled, except the one a mode
// holds open on purpose - counted explicitly, so the condition cannot be
// satisfied before that request has even been issued. A fixed sleep would count
// a render slower than the sleep as missing cards and fail on a page that
// completed correctly.
function settle(state, maxTurns = 1000) {
  const done = () => state.issued > 0 && state.settled + state.held === state.issued;
  return new Promise((resolve) => {
    let turns = 0;
    const turn = () => {
      if (done() || turns++ >= maxTurns) return resolve();
      setTimeout(turn, 0);
    };
    turn();
  });
}

// `stall` makes the OPTIONAL plugin request hang rather than fail - the shape
// that left the catalogue blank before the fetch was decoupled from the render.
function render(stall) {
  const hosts = {};
  for (const id of ["catalog-list", "plugin-list", "stat-count", "toast"]) hosts[id] = el("div");
  const unexpected = [];
  const state = { issued: 0, settled: 0, held: 0 };
  const sandbox = {
    document: {
      readyState: "complete", createElement: el, addEventListener() {}, body: el("body"),
      getElementById: (id) => hosts[id] || null,
    },
    fetch: (url) => {
      // Only the page's own two catalogue URLs are served, base included, so a
      // mistyped host, repository or branch fails here instead of quietly
      // reading a local file while the deployed page renders nothing.
      const abs = String(url);
      const rel = abs.indexOf(RAW_BASE) === 0
        ? [CATALOG, PLUGINS].find((p) => abs === RAW_BASE + p)
        : undefined;
      state.issued++;
      if (!rel) {
        unexpected.push(abs);
        return Promise.resolve({ ok: false, status: 404, text: () => Promise.resolve("") });
      }
      if (stall && rel === PLUGINS) { state.held++; return new Promise(() => {}); }
      const f = path.join(ROOT, rel);
      if (!fs.existsSync(f)) {
        unexpected.push(`${abs} (no local file at ${rel})`);
        return Promise.resolve({ ok: false, status: 404, text: () => Promise.resolve("") });
      }
      return Promise.resolve({ ok: true, status: 200, text: () => Promise.resolve(fs.readFileSync(f, "utf8")) })
        .then((r) => { state.settled++; return r; });
    },
    navigator: {}, console, setTimeout, clearTimeout, Promise, Error, JSON,
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(ROOT, "assets/site.js"), "utf8"), sandbox,
    { filename: "assets/site.js" });
  return settle(state).then(() => ({
    schematicCards: hosts["catalog-list"].querySelectorAll("article.catalog-card").length,
    pluginCards: hosts["plugin-list"].querySelectorAll("article.catalog-card").length,
    emptyStateShown: hosts["catalog-list"].querySelector(".catalog-empty") !== null,
    heroStat: hosts["stat-count"].textContent,
    unexpected,
    issued: state.issued,
  }));
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
// A page that fetched something the check does not serve was measured on data
// the real page would not have: report the URLs rather than the count.
function checkNone(label, list) {
  const ok = list.length === 0;
  if (!ok) failures.push(`${label}: ${list.join(", ")}`);
  console.log(`  ${ok ? "ok  " : "FAIL"} ${label} = ${list.length}`);
}

(async () => {
  const { featured, authoring, total } = expected();
  console.log(`catalogues: ${total} schematic entries (${featured} featured), ${authoring} authoring plugin`);

  console.log("\nplugin marketplace available:");
  const normal = await render(false);
  checkNone("unexpected fetches", normal.unexpected);
  check("schematic cards", normal.schematicCards, featured);
  check("plugin cards", normal.pluginCards, authoring);
  check("hero count", normal.heroStat, String(featured));
  check("empty state shown", normal.emptyStateShown, false);

  console.log("\nplugin marketplace STALLS - the catalogue must still render:");
  const stalled = await render(true);
  checkNone("unexpected fetches", stalled.unexpected);
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
