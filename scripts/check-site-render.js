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
// And it covers the page a reader gets without JavaScript. index.html serves
// its counts as markup, because a crawler, curl or an LLM summarising the site
// never runs the script - a placeholder there is what told every machine reader
// the catalogue was empty (#67). The hero states how many schematics are
// PUBLISHED (every catalogue entry that is not the authoring plugin) and the
// grid renders the featuring SUBSET of them, saying so in the catalog note, so
// the numbers a reader is told and the cards they can count agree about which
// set each one is. Both are asserted against the catalogue here, served and
// rendered, so neither can drift when a schematic is added or featured.
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
// The page a reader gets with no JavaScript at all: its hero count is markup,
// and site.js recomputes the same number from the catalogue at load time.
const SERVED_PAGE = "index.html";
// The build-report issue form a schematic card links to, as assets/site.js
// builds it. A URL is not a fetch, so it needs no entry in the allow-list
// below - but it is asserted per card, because a dead report link is invisible
// on the page that offers it.
const REPORT_URL = "https://github.com/cameri/schematics/issues/new" +
  "?template=build-report.yml&title=";

// The predicates below must match renderCatalog / renderPluginSection in
// assets/site.js. If the site's filter changes, change it here too - the point
// of this file is to fail when those two drift apart.
// Two sets, matching the two the page distinguishes: every published schematic
// (what the hero stat counts) and the featured subset (what the grid renders).
const isPublishedEntry = (e) => e.category !== "authoring";
const isFeaturedEntry = (e) => isPublishedEntry(e) && !!e.featured;
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
  for (const id of ["catalog-list", "plugin-list", "stat-count", "toast",
                    "catalog-shown", "catalog-total"]) hosts[id] = el("div");
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
    // The grid is a labelled subset, so it carries both numbers: how many cards
    // it shows and how many published schematics exist. They are asserted
    // against the catalogue, not against each other.
    catalogShown: hosts["catalog-shown"].textContent,
    catalogTotal: hosts["catalog-total"].textContent,
    // The build-report links the cards offer, in catalog order, so the check
    // can assert each one carries its own schematic's name into the form.
    reportLinks: hosts["catalog-list"].querySelectorAll("a.cat-report").map((n) => n.href),
    pluginReportLinks: hosts["plugin-list"].querySelectorAll("a.cat-report").length,
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
  const publishedEntries = catalog.schematics.filter(isPublishedEntry);
  const featuredEntries = catalog.schematics.filter(isFeaturedEntry);
  const published = publishedEntries.length;
  const featured = featuredEntries.length;
  const authoring = (plugins.plugins || []).filter(isPluginEntry).length;
  if (published === 0) throw new Error(`${CATALOG} has no published entries - nothing would render`);
  if (featured === 0) throw new Error(`${CATALOG} has no featured entries - the grid would be empty`);
  if (authoring !== 1) throw new Error(`${PLUGINS} should hold exactly one authoring plugin, found ${authoring}`);
  return {
    published, featured, authoring, total: catalog.schematics.length,
    // One report link per card, each naming the schematic it belongs to.
    reportLinks: featuredEntries.map((e) => REPORT_URL + encodeURIComponent("build-report: " + e.name)),
  };
}

// Text the served page carries before any script runs, found by element id. A
// crawler, curl or an LLM summarising the site reads this HTML and never
// executes site.js, so every count the page states has to be right here as
// well - the assertion is what keeps it from drifting when either number moves.
function servedText(id) {
  const html = fs.readFileSync(path.join(ROOT, SERVED_PAGE), "utf8");
  const m = html.match(new RegExp(`<([a-z]+)\\b[^>]*\\bid="${id}"[^>]*>([\\s\\S]*?)</\\1>`));
  if (!m) {
    throw new Error(`${SERVED_PAGE} has no element with id="${id}": the number ` +
      `a reader without JavaScript sees is gone, and the page falls back to ` +
      `whatever site.js writes at load time`);
  }
  return m[2].trim();
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
// A list whose members matter (not just its length): report the first
// disagreement, because "got 5, want 5" has already passed by then.
function checkList(label, got, want) {
  const bad = want.findIndex((w, i) => got[i] !== w);
  const ok = got.length === want.length && bad === -1;
  if (!ok) {
    const at = bad === -1 ? Math.min(got.length, want.length) : bad;
    failures.push(`${label}: ${want.length} expected, ${got.length} rendered; ` +
      `first difference at ${at + 1}: got ${JSON.stringify(got[at])}, ` +
      `want ${JSON.stringify(want[at])}`);
  }
  console.log(`  ${ok ? "ok  " : "FAIL"} ${label} = ${got.length}`);
}

(async () => {
  const { published, featured, authoring, total, reportLinks } = expected();
  console.log(`catalogues: ${total} catalog entries (${published} published, ${featured} featured), ` +
    `${authoring} authoring plugin`);

  // No JavaScript at all: this is the whole page a crawler or curl sees.
  console.log("\nserved index.html (what a machine reader gets before site.js runs):");
  check("published count in the served markup", servedText("stat-count"), String(published));
  check("grid size in the served markup", servedText("catalog-shown"), String(featured));
  check("catalog total in the served markup", servedText("catalog-total"), String(published));

  console.log("\nplugin marketplace available:");
  const normal = await render(false);
  checkNone("unexpected fetches", normal.unexpected);
  check("hero count = published schematics", normal.heroStat, String(published));
  check("schematic cards = featured schematics", normal.schematicCards, featured);
  check("note: cards shown", normal.catalogShown, String(featured));
  check("note: published total", normal.catalogTotal, String(published));
  check("plugin cards", normal.pluginCards, authoring);
  check("empty state shown", normal.emptyStateShown, false);
  checkList("build-report links", normal.reportLinks, reportLinks);
  check("build-report links on the plugin card", normal.pluginReportLinks, 0);

  console.log("\nplugin marketplace STALLS - the catalogue must still render:");
  const stalled = await render(true);
  checkNone("unexpected fetches", stalled.unexpected);
  check("hero count = published schematics", stalled.heroStat, String(published));
  check("schematic cards = featured schematics", stalled.schematicCards, featured);
  check("note: published total", stalled.catalogTotal, String(published));
  check("plugin cards", stalled.pluginCards, 0);

  if (failures.length) {
    console.error(`\nFAILED (${failures.length}):`);
    for (const f of failures) console.error(`  - ${f}`);
    process.exit(1);
  }
  console.log("\nall render checks passed");
})().catch((err) => { console.error(`check-site-render: ${err.message}`); process.exit(2); });
