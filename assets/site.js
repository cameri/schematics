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
    var host = document.getElementById("catalog");
    if (!host) return;

    // Hero stat: schematic count
    var statCount = document.getElementById("stat-count");
    if (statCount) statCount.textContent = String(plugins.length);

    if (!plugins || !plugins.length) {
      host.appendChild(el("div", "catalog-empty", "No schematics published yet."));
      return;
    }

    plugins.forEach(function (plugin) {
      var card = el("article", "catalog-card");
      card.appendChild(el("h3", null, plugin.name));

      var desc = el("p", "cat-desc", plugin.description || "");
      card.appendChild(desc);

      // Meta chips: category, source path
      var meta = el("div", "cat-meta");
      if (plugin.category) meta.appendChild(el("span", null, plugin.category));
      if (plugin.source) meta.appendChild(el("span", null, plugin.source));
      card.appendChild(meta);

      // Actions: Copy as Markdown + Open on GitHub
      var actions = el("div", "cat-actions");

      var copyBtn = el("button", "cat-btn primary", "Copy as Markdown");
      copyBtn.type = "button";
      copyBtn.addEventListener("click", function () {
        // "spec" overrides the default SCHEMATIC.md (e.g. the create-schematic
        // plugin publishes its SKILL.md as the copyable artifact).
        var specUrl = plugin.source + "/" + (plugin.spec || "SCHEMATIC.md");
        copyBtn.disabled = true;
        copyBtn.textContent = "Fetching…";
        fetchText(specUrl)
          .then(function (md) {
            return copyText(md).then(function () {
              toast("Copied " + plugin.name + " schematic (" + md.length + " chars)");
            });
          })
          .catch(function (err) {
            toast("Failed to copy: " + err.message, true);
          })
          .finally(function () {
            copyBtn.disabled = false;
            copyBtn.textContent = "Copy as Markdown";
          });
      });
      actions.appendChild(copyBtn);

      var ghBtn = el("a", "cat-btn", "GitHub ↗");
      ghBtn.href = "https://github.com/cameri/schematics/tree/main/" + plugin.source;
      ghBtn.target = "_blank";
      ghBtn.rel = "noopener";
      actions.appendChild(ghBtn);

      card.appendChild(actions);
      host.appendChild(card);
    });
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
        var host = document.getElementById("catalog");
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