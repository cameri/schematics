/* Agentic Schematics — site logic. Renders .agent-schematics/marketplace.json
   and implements one-click "copy build command": no spec text is embedded or
   fetched; the copied artifact is `build <name>@cameri/schematics` (agent
   fetches the spec itself), plus the authoring plugin's per-harness install
   commands. Vanilla JS, no build step, cached by GH Pages. */

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

  // The copyable artifact is a command, never the spec text. The build literal
  // works in any agent; the spec URL is the pluginless fallback, so the page
  // never embeds or fetches a spec.
  function buildCommand(plugin) {
    return "build " + plugin.name + "@cameri/schematics\n\n" +
      "# No plugin? Paste this and let the agent fetch the spec:\n" +
      "# https://schemaformat.ai/schematics/" + plugin.name + "/SCHEMATIC.md";
  }

  var INSTALL_COMMAND = [
    "# Claude Code",
    "claude plugin marketplace add cameri/schematics",
    "claude plugin install schematics@cameri-schematics",
    "# Pi / omp",
    "omp plugin marketplace add cameri/schematics",
    "omp plugin install schematics@cameri-schematics",
  ].join("\n");

  // ─── Catalog rendering ─────────────────────────────────────
  function renderCatalog(entries) {
    var host = document.getElementById("catalog-list");
    if (!host) return;

    // Plugins and schematics are different things: capability entries carry a
    // SCHEMATIC.md build spec; the authoring entry is the plugin that creates
    // them. They render into separate hosts and never mix.
    // The main page shows ONLY featured schematics - the featured flag is
    // the curation mechanism that keeps the page from growing indefinitely.
    // Everything else stays in the catalog and on GitHub.
    var schematics = (entries || [])
      .filter(function (p) { return p.category !== "authoring" && p.featured; });

    // Hero stat: schematic count (the authoring plugin is not a schematic)
    var statCount = document.getElementById("stat-count");
    if (statCount) statCount.textContent = String(schematics.length);

    // Idempotent: a re-run of init must not duplicate cards.
    host.innerHTML = "";
    if (!schematics.length) {
      host.appendChild(el("div", "catalog-empty", "No schematics published yet."));
    }

    schematics.forEach(function (plugin) {
      host.appendChild(renderCard(plugin, false));
    });

    // Clear the plugin host here, so a catalog re-render stays idempotent even
    // when the plugin marketplace is slow, absent or fails.
    var pluginHost = document.getElementById("plugin-list");
    if (pluginHost) pluginHost.innerHTML = "";
  }

  // The plugin section is filled separately, and later than the catalog: the
  // authoring plugin lives in its own marketplace and the catalog must not
  // wait on it. A request that never settles leaves this section empty, which
  // is the honest degrade - it must not leave the schematics blank.
  function renderPluginSection(pluginEntries) {
    var pluginHost = document.getElementById("plugin-list");
    if (!pluginHost) return;
    pluginHost.innerHTML = ""; // idempotent: a late settle must not duplicate
    var pluginEntry = (pluginEntries || []).find(function (p) { return p.category === "authoring"; });
    if (pluginEntry) pluginHost.appendChild(renderCard(pluginEntry, true));
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
    if (plugin.composes && plugin.composes.length) {
      var comp = el("span", "cat-kind kind-composes",
        "composes " + plugin.composes.join(" + "));
      comp.title = "Composition schematic: wires " +
        plugin.composes.join(", ") + " into one stack";
      head.appendChild(comp);
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

      // Copy the build command, never the spec text. Authoring card copies
      // the harness install commands.
      var copyBtn = el("button", "cat-btn primary",
        isAuthoring ? "Copy install command" : "Copy build command");
      copyBtn.type = "button";
      copyBtn.addEventListener("click", function () {
        var text = isAuthoring ? INSTALL_COMMAND : buildCommand(plugin);
        var what = isAuthoring ? "install command" : "build command for " + plugin.name;
        copyText(text).then(function () {
          toast("Copied " + what);
        }).catch(function (err) {
          toast("Failed to copy: " + err.message, true);
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
    // The catalog and the authoring plugin are two files since the split:
    // .agent-schematics/marketplace.json holds the schematics, and
    // .claude-plugin/marketplace.json holds the plugin that authors them.
    // This page renders both, so it reads both - the plugin entry no longer
    // travels inside the schematics array, and searching that array for it
    // leaves the plugin section empty.
    function fetchPluginEntries() {
      return fetchText(RAW_BASE + ".claude-plugin/marketplace.json")
        .then(function (json) {
          return JSON.parse(json).plugins || [];
        })
        .catch(function (err) {
          // The catalog is the page; the plugin card is a convenience. Report
          // the failure and still render the schematics.
          console.error("plugin marketplace load failed:", err);
          return [];
        });
    }

    fetchText(RAW_BASE + ".agent-schematics/marketplace.json")
      .then(function (json) {
        var data;
        try {
          data = JSON.parse(json);
        } catch (e) {
          throw new Error("marketplace.json is not valid JSON");
        }
        // Draw the catalog now. The plugin marketplace is optional and must
        // not gate it: awaiting it here is what left the whole page blank
        // whenever that request stalled instead of failing.
        renderCatalog(data.schematics);
        return fetchPluginEntries();
      })
      .then(function (plugins) {
        renderPluginSection(plugins);
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