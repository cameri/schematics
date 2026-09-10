/* ─── Agentic Schematics — site logic ────────────────────────── */
//
// Renders the schematic catalog from .agent-schematics/marketplace.json
// and implements one-click "copy as Markdown" (fetches SCHEMATIC.md).
// Dependency-free vanilla JS — no build step, everything cached by GH Pages.

(function () {
  "use strict";

  // Repo base for raw file fetches via GitHub's raw CDN.
  // Using raw.githubusercontent.com because GH Pages doesn't serve
  // files from dotfile directories (.agent-schematics). This also
  // makes the site work on any domain, not just GH Pages.
  var RAW_BASE = "https://raw.githubusercontent.com/cameri/schematics/main/";

  // ─── Helpers ───────────────────────────────────────────────
  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  var toastTimer = null;
  function toast(message, isError) {
    var t = document.getElementById("toast");
    t.textContent = message;
    t.className = "toast show" + (isError ? " error" : "");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () {
      t.className = "toast";
    }, 2600);
  }

  function fetchText(url) {
    return fetch(url).then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.text();
    });
  }

  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text);
    }
    // Fallback for older browsers / non-secure contexts
    return new Promise(function (resolve, reject) {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      try {
        document.execCommand("copy");
        resolve();
      } catch (e) {
        reject(e);
      } finally {
        document.body.removeChild(ta);
      }
    });
  }

  // ─── Catalog rendering ─────────────────────────────────────
  function renderCatalog(plugins) {
    var host = document.getElementById("catalog-list");
    if (!host) return;

    // Plugins and schematics are different things: capability entries carry a
    // SCHEMATIC.md build spec; the authoring entry is the plugin that creates
    // them. They render into separate hosts and never mix.
    var schematics = (plugins || [])
      .filter(function (p) { return p.category !== "authoring"; })
      .sort(function (a, b) { return (b.featured ? 1 : 0) - (a.featured ? 1 : 0); });
    var pluginEntry = (plugins || []).find(function (p) { return p.category === "authoring"; });

    // Hero stat: schematic count (the authoring plugin is not a schematic)
    var statCount = document.getElementById("stat-count");
    if (statCount) statCount.textContent = String(schematics.length);

    if (!schematics.length) {
      host.appendChild(el("div", "catalog-empty", "No schematics published yet."));
    }

    schematics.forEach(function (plugin) {
      host.appendChild(renderCard(plugin, false));
    });

    var pluginHost = document.getElementById("plugin-list");
    if (pluginHost && pluginEntry) {
      pluginHost.appendChild(renderCard(pluginEntry, true));
    }
  }

  function renderCard(plugin, isAuthoring) {
    var card = el("article", "catalog-card");

    var head = el("div", "cat-head");
    head.appendChild(el("h3", null, plugin.name));
    if (isAuthoring) {
      head.appendChild(el("span", "cat-kind kind-authoring", "plugin · authoring"));
    }
    if (plugin.featured) {
      head.appendChild(el("span", "cat-kind kind-featured", "featured"));
    }
    card.appendChild(head);

      var desc = el("p", "cat-desc", plugin.description || "");
      card.appendChild(desc);

      // Meta chips: category, source path
      var meta = el("div", "cat-meta");
      if (plugin.category) meta.appendChild(el("span", null, plugin.category));
      if (plugin.source) meta.appendChild(el("span", null, plugin.source));
      card.appendChild(meta);
      var actions = el("div", "cat-actions");

      // The copyable artifact: the schematic spec (SCHEMATIC.md) for
      // capability plugins; the skill definition for the authoring plugin.
      var copyBtn = el("button", "cat-btn primary",
        isAuthoring ? "Copy skill definition" : "Copy schematic");
      copyBtn.type = "button";
      copyBtn.addEventListener("click", function () {
        var specUrl = plugin.source + "/" + (plugin.spec || "SCHEMATIC.md");
        var busyLabel = "Fetching…";
        var doneLabel = isAuthoring ? "Copy skill definition" : "Copy schematic";
        copyBtn.disabled = true;
        copyBtn.textContent = busyLabel;
        fetchText(specUrl)
          .then(function (md) {
            return copyText(md).then(function () {
              toast("Copied " + plugin.name + " (" + md.length + " chars)");
            });
          })
          .catch(function (err) {
            toast("Failed to copy: " + err.message, true);
          })
          .finally(function () {
            copyBtn.disabled = false;
            copyBtn.textContent = doneLabel;
          });
      });
      actions.appendChild(copyBtn);

      var ghBtn = el("a", "cat-btn", "GitHub ↗");
      ghBtn.href = "https://github.com/cameri/schematics/tree/main/" + plugin.source;
      ghBtn.target = "_blank";
      ghBtn.rel = "noopener";
      actions.appendChild(ghBtn);

      card.appendChild(actions);
    return card;
  }

  // ─── Init ──────────────────────────────────────────────────
  function init() {
    fetchText(RAW_BASE + ".agent-schematics/marketplace.json")
      .then(function (json) {
        var data;
        try {
          data = JSON.parse(json);
        } catch (e) {
          throw new Error("marketplace.json is not valid JSON");
        }
        renderCatalog(data.plugins);
      })
      .catch(function (err) {
        console.error("catalog load failed:", err);
        var host = document.getElementById("catalog-list");
        if (host) {
          host.appendChild(
            el("div", "catalog-empty", "Couldn't load the catalog: " + err.message)
          );
        }
      });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();