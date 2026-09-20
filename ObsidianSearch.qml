import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "FuzzySearch.js" as FuzzySearch

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property var items: []
  property var allItems: []
  property var vaults: []
  property var queryInfo: ({
      "vault": null,
      "token": "",
      "rest": "",
      "text": "",
      "tags": [],
      "tagToken": "",
      "tagPicking": false,
      "props": [],
      "propToken": null,
      "propPicking": false,
      "picking": false
    })
  readonly property string scopeText: root.scopeSummary(root.queryInfo)
  property bool configReady: false
  property var pendingLaunch: []
  property bool hasPendingLaunch: false
  readonly property string searchScript: Qt.resolvedUrl("search.sh").toString().replace(/^file:\/\//, "")
  readonly property string ensureScript: Qt.resolvedUrl("ensure-note.sh").toString().replace(/^file:\/\//, "")

  // Shares the [menu] surface tokens so themes style it like the menu.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(520), panel.width - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(44), Style.font.body + Style.spacing.rowPaddingX * 2)
  property int cardHeight: Math.min(contentMargin * 2 + headerHeight + contentSpacing + rowHeight * Math.min(root.items.length, 9) + Style.space(8), panel.height - Style.gapsOut * 2)
  property int searchSerial: 0
  property bool searchPending: false

  function open(payloadJson) {
    root.opened = true;
    root.filterText = "";
    root.selectedIndex = 0;
    root.cursorActive = true;
    root.disarmPointer();
    root.filter();
    if (!searchProc.running)
      root.runSearch();
    Qt.callLater(function () {
        keyCatcher.forceActiveFocus();
      });
  }

  function close() {
    root.opened = false;
  }

  function toggle() {
    if (root.opened)
      root.close();
    else
      root.open("{}");
  }

  function runSearch() {
    if (searchProc.running) {
      root.searchPending = true;
      return;
    }
    root.searchSerial += 1;
    searchProc.serial = root.searchSerial;
    searchProc.collected = "";
    var args = [root.searchScript];
    // Without an explicit vault the script lists every vault Obsidian knows,
    // which is what makes @vault a filter rather than a switch.
    var configured = root.configuredVaultPaths();
    for (var i = 0; i < configured.length; i++)
      args.push("--vault=" + configured[i]);
    args.push("--show-daily=" + (root.cfgBool("showDailyNotes", true) ? "1" : "0"));
    args.push("--show-templates=" + (root.cfgBool("showTemplates", false) ? "1" : "0"));
    searchProc.command = args;
    searchProc.running = true;
  }

  property var fileConfig: ({})
  function parseFileConfig(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""));
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : ({});
    } catch (e) {
      return ({});
    }
  }
  function cfg(name, fallback) {
    var value = root.fileConfig ? root.fileConfig[name] : undefined;
    return value === undefined || value === null ? fallback : value;
  }
  function cfgBool(name, fallback) {
    var raw = root.cfg(name, "");
    if (raw === "")
      return fallback;
    if (raw === true)
      return true;
    if (raw === false)
      return false;
    var lowered = String(raw).toLowerCase();
    if (lowered === "true" || lowered === "1" || lowered === "yes")
      return true;
    if (lowered === "false" || lowered === "0" || lowered === "no")
      return false;
    return fallback;
  }
  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.config/omarchy/obsidian-focused-search.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.fileConfig = root.parseFileConfig(text());
      root.configReady = true;
      root.onConfigChanged();
    }
    onFileChanged: configFile.reload()
    onLoadFailed: {
      root.fileConfig = ({});
      root.configReady = true;
      root.onConfigChanged();
    }
  }

  // Re-lists with the new showDailyNotes/showTemplates flags once the config
  // arrives or changes, and prewarms the cache at shell startup so the first
  // open is instant. Cached rows stay visible until the fresh list lands.
  function onConfigChanged() {
    root.filter();
    root.runSearch();
  }

  // Every row model shares one shape so ListModel roles stay stable whether
  // the list holds notes, daily pins, create rows or the @vault picker.
  function makeRow(icon, label, detail, action, kind, rel, vault, tags, props) {
    return {
      "icon": icon,
      "label": label,
      "detail": detail,
      "action": action,
      "title": label,
      "domain": vault,
      "tags": tags || [],
      "props": props || [],
      "link": String(action).indexOf("obsidian://open") === 0 ? action : "",
      "kind": kind,
      "rel": rel,
      "vault": vault
    };
  }

  function parseResults(raw) {
    var lines = String(raw || "").split("\n");
    var rows = [];
    var found = [];
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim();
      if (!line)
        continue;
      if (line.indexOf("#vault\t") === 0) {
        var head = line.split("\t");
        if (head.length >= 5 && head[1] && head[2].charAt(0) === "/")
          found.push({
              "name": head[1],
              "path": head[2].replace(/\/$/, ""),
              "daily": head[3] === "1",
              "obsidianName": head[4]
            });
        continue;
      }
      var parts = line.split("\t");
      if (parts.length < 7)
        continue;
      var uri = parts[parts.length - 1];
      if (uri.indexOf("obsidian://") !== 0)
        continue;
      var path = parts[2];
      var vault = parts[3];
      var tags = parts[4] ? parts[4].split(" ").filter(function (t) {
        return t.length > 0;
      }) : [];
      var props = parts[5] ? parts[5].split("\u001f").filter(function (p) {
        return p.indexOf("=") > 0;
      }) : [];
      var kind = parts[1];
      var icon = "󰠮";
      if (kind === "Canvas")
        icon = "󰇞";
      else if (kind === "Base")
        icon = "";
      else if (kind === "Daily Note")
        icon = "";
      else if (kind === "Template")
        icon = "󱘒";
      var detail = kind + " \u00b7 " + vault;
      if (tags.length > 0)
        detail += " \u00b7 #" + tags.slice(0, 3).join(" #") + (tags.length > 3 ? " \u2026" : "");
      rows.push(root.makeRow(icon, parts[0], detail, uri, kind, path, vault, tags, props));
    }
    root.vaults = found;
    return rows;
  }

  // --- @vault scoping ---------------------------------------------------
  // A leading "@" turns the first token into a vault selector: "@work" opens
  // the picker, "@work meeting" searches only inside that vault. Names are
  // compared with case and punctuation stripped, so "@my-kb", "@MyKB" and
  // "@mykb" all land on the same vault.
  function vaultKey(name) {
    return String(name || "").toLowerCase().replace(/[^a-z0-9]/g, "");
  }

  function configuredVaultPaths() {
    var raw = root.cfg("vaultPaths", null);
    if (!raw || !Array.isArray(raw)) {
      var single = root.cfg("vaultPath", "");
      raw = single ? [single] : [];
    }
    var out = [];
    for (var i = 0; i < raw.length; i++) {
      var p = String(raw[i] || "").trim();
      if (!p)
        continue;
      if (p.indexOf("~/") === 0)
        p = Quickshell.env("HOME") + p.slice(1);
      out.push(p);
    }
    return out;
  }

  function primaryVault() {
    return root.vaults.length > 0 ? root.vaults[0] : null;
  }

  function vaultByName(name) {
    var key = root.vaultKey(name);
    for (var i = 0; i < root.vaults.length; i++)
      if (root.vaultKey(root.vaults[i].name) === key)
        return root.vaults[i];
    return null;
  }

  // Picker candidates: exact match first, then prefixes, then names merely
  // containing the token. An empty token lists every vault.
  function matchVaults(token) {
    var key = root.vaultKey(token);
    if (!key)
      return root.vaults.slice();
    var exact = [];
    var prefix = [];
    var contains = [];
    for (var i = 0; i < root.vaults.length; i++) {
      var k = root.vaultKey(root.vaults[i].name);
      if (k === key)
        exact.push(root.vaults[i]);
      else if (k.indexOf(key) === 0)
        prefix.push(root.vaults[i]);
      else if (k.indexOf(key) !== -1)
        contains.push(root.vaults[i]);
    }
    return exact.concat(prefix).concat(contains);
  }

  // --- #tag filtering ---------------------------------------------------
  // "#tag" tokens anywhere after the optional @vault narrow the results to
  // notes carrying every one of them. A trailing, still-open "#tok" opens the
  // tag picker, listing the tags present in whatever the query already
  // selected, so tags can be stacked by drilling down.
  function tagKey(tag) {
    return String(tag || "").toLowerCase().replace(/^#+/, "").replace(/\/+$/, "");
  }

  // A parent tag matches its nested children, so "#work" also finds
  // "#work/hiring", which is how Obsidian treats tag hierarchies.
  function rowHasTag(row, tag) {
    var key = root.tagKey(tag);
    if (!key)
      return true;
    var list = row.tags || [];
    for (var i = 0; i < list.length; i++) {
      var k = root.tagKey(list[i]);
      if (k === key || k.indexOf(key + "/") === 0)
        return true;
    }
    return false;
  }

  function rowHasAllTags(row, tags) {
    for (var i = 0; i < tags.length; i++)
      if (!root.rowHasTag(row, tags[i]))
        return false;
    return true;
  }

  // Every tag present in the given rows, most used first, so the picker
  // always reflects the current vault and tag scope rather than a global list.
  function tagCounts(pool) {
    var map = ({});
    var keys = [];
    for (var i = 0; i < pool.length; i++) {
      var list = pool[i].tags || [];
      for (var j = 0; j < list.length; j++) {
        var key = root.tagKey(list[j]);
        if (!key)
          continue;
        if (!map[key]) {
          map[key] = {
            "name": list[j],
            "count": 0
          };
          keys.push(key);
        }
        map[key].count += 1;
      }
    }
    var out = [];
    for (var k = 0; k < keys.length; k++)
      out.push(map[keys[k]]);
    out.sort(function (a, b) {
      return b.count - a.count || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
    });
    return out;
  }

  function matchTags(token, pool) {
    var key = root.tagKey(token);
    var all = root.tagCounts(pool);
    if (!key)
      return all;
    var prefix = [];
    var contains = [];
    for (var i = 0; i < all.length; i++) {
      var k = root.tagKey(all[i].name);
      if (k.indexOf(key) === 0)
        prefix.push(all[i]);
      else if (k.indexOf(key) !== -1)
        contains.push(all[i]);
    }
    return prefix.concat(contains);
  }

  function tagRow(tag, vaultName) {
    return root.makeRow("󰓹", "#" + tag.name, tag.count + (tag.count === 1 ? " note" : " notes"), "", "Tag", "", vaultName, [], []);
  }

  // --- :property filtering ----------------------------------------------
  // ":key=value" tokens narrow to notes whose YAML frontmatter carries that
  // property. Typing ":" lists the property keys present in the current
  // selection; confirming one leaves ":key=" open, which lists that key's
  // values - so ":author" answers "which authors do I have?" in two keys.
  // Values are compared case-insensitively as substrings, and a bare ":key"
  // filter keeps every note that has the property at all.
  function propKey(name) {
    return String(name || "").toLowerCase().replace(/^:+/, "").trim();
  }

  function propPair(entry) {
    var s = String(entry || "");
    var eq = s.indexOf("=");
    return eq <= 0 ? null : {
      "key": s.slice(0, eq).toLowerCase(),
      "value": s.slice(eq + 1)
    };
  }

  function rowHasProp(row, want) {
    var key = root.propKey(want.key);
    if (!key)
      return true;
    var list = row.props || [];
    var needle = want.value === null || want.value === undefined ? null : String(want.value).toLowerCase();
    for (var i = 0; i < list.length; i++) {
      var pair = root.propPair(list[i]);
      if (!pair || pair.key !== key)
        continue;
      if (needle === null || pair.value.toLowerCase().indexOf(needle) !== -1)
        return true;
    }
    return false;
  }

  function rowHasAllProps(row, props) {
    for (var i = 0; i < props.length; i++)
      if (!root.rowHasProp(row, props[i]))
        return false;
    return true;
  }

  // Counts the distinct property keys, or - when a key is given - that key's
  // distinct values, across the rows the query already selected.
  function propCounts(pool, forKey) {
    var key = root.propKey(forKey);
    var map = ({});
    var order = [];
    for (var i = 0; i < pool.length; i++) {
      var list = pool[i].props || [];
      var local = ({});
      for (var j = 0; j < list.length; j++) {
        var pair = root.propPair(list[j]);
        if (!pair)
          continue;
        var name;
        if (key) {
          if (pair.key !== key)
            continue;
          name = pair.value;
        } else {
          name = pair.key;
        }
        var id = name.toLowerCase();
        if (local[id])
          continue;
        local[id] = true;
        if (!map[id]) {
          map[id] = {
            "name": name,
            "count": 0
          };
          order.push(id);
        }
        map[id].count += 1;
      }
    }
    var out = [];
    for (var k = 0; k < order.length; k++)
      out.push(map[order[k]]);
    out.sort(function (a, b) {
      return b.count - a.count || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
    });
    return out;
  }

  function matchProps(token, pool, forKey) {
    var key = String(token || "").toLowerCase();
    var all = root.propCounts(pool, forKey);
    if (!key)
      return all;
    var prefix = [];
    var contains = [];
    for (var i = 0; i < all.length; i++) {
      var k = all[i].name.toLowerCase();
      if (k.indexOf(key) === 0)
        prefix.push(all[i]);
      else if (k.indexOf(key) !== -1)
        contains.push(all[i]);
    }
    return prefix.concat(contains);
  }

  function propKeyRow(entry, vaultName) {
    return root.makeRow("󰌆", ":" + entry.name, entry.count + (entry.count === 1 ? " note" : " notes"), "", "PropKey", "", vaultName, [], []);
  }

  function propValueRow(key, entry, vaultName) {
    return root.makeRow("󰌆", entry.name, key + " · " + entry.count + (entry.count === 1 ? " note" : " notes"), "", "PropValue", key, vaultName, [], []);
  }

  // A value with spaces has to survive the whitespace tokenizer, so quote it.
  function propText(key, value) {
    if (value === null || value === undefined)
      return ":" + key;
    var needsQuotes = /[\s"]/.test(String(value));
    return ":" + key + "=" + (needsQuotes ? "\"" + String(value).replace(/"/g, "") + "\"" : value);
  }

  // Rebuilds the "@vault #tag :key=value " prefix of a query without its free
  // text, used when Escape peels a layer or the picker confirms a choice.
  function scopePrefix(vault, tags, props) {
    var out = vault ? "@" + vault.name + " " : "";
    for (var i = 0; i < tags.length; i++)
      out += "#" + tags[i] + " ";
    var list = props || [];
    for (var j = 0; j < list.length; j++)
      out += root.propText(list[j].key, list[j].value) + " ";
    return out;
  }

  function scopeSummary(q) {
    var parts = [];
    if (q.vault)
      parts.push(q.vault.name);
    else if (root.vaults.length > 1)
      parts.push("All vaults");
    var tags = q.tags || [];
    for (var i = 0; i < tags.length; i++)
      parts.push("#" + tags[i]);
    var props = q.props || [];
    for (var j = 0; j < props.length; j++)
      parts.push(":" + props[j].key + (props[j].value === null ? "" : "=" + props[j].value));
    return parts.join("  ");
  }

  // The query minus the token still being typed. Quote-aware, so it drops all
  // of :author="Marty Ca rather than stopping at the space inside the quotes.
  function withoutOpenToken() {
    var raw = String(root.filterText || "");
    var cut = 0;
    var quoted = false;
    for (var i = 0; i < raw.length; i++) {
      var c = raw.charAt(i);
      if (c === "\"")
        quoted = !quoted;
      else if (!quoted && /\s/.test(c))
        cut = i + 1;
    }
    return raw.slice(0, cut);
  }

  // Whitespace splits tokens, except inside double quotes, which is what lets
  // :author="Marty Cagan" stay a single token.
  function tokenize(text) {
    var out = [];
    var cur = "";
    var has = false;
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      var c = text.charAt(i);
      if (c === "\"") {
        quoted = !quoted;
        has = true;
        continue;
      }
      if (!quoted && /\s/.test(c)) {
        if (has)
          out.push(cur);
        cur = "";
        has = false;
        continue;
      }
      cur += c;
      has = true;
    }
    if (has)
      out.push(cur);
    return out;
  }

  // Parses the raw filter into { vault, token, picking, tags, tagToken,
  // tagPicking, rest, text }. While either token is still unterminated the
  // menu stays in picker mode, so the scope is always confirmed before
  // results silently narrow.
  function queryState() {
    var raw = String(root.filterText || "");
    var open = raw.length > 0 && !/\s$/.test(raw);
    var vault = null;
    var token = "";
    var rest = raw.trim();
    var m = /^@(\S*)(\s+([\s\S]*))?$/.exec(raw);
    if (m) {
      token = m[1];
      // "@ query" carries no vault name, so it stays in the picker rather
      // than silently scoping to whichever vault happens to sort first.
      var candidates = m[2] !== undefined && root.vaultKey(token) ? root.matchVaults(token) : [];
      vault = candidates.length > 0 ? candidates[0] : null;
      if (!vault)
        return {
          "vault": null,
          "token": token,
          "rest": "",
          "text": "",
          "tags": [],
          "tagToken": "",
          "tagPicking": false,
          "props": [],
          "propToken": null,
          "propPicking": false,
          "picking": true
        };
      rest = String(m[3] || "").trim();
    }
    var tags = [];
    var props = [];
    var words = [];
    var tagToken = "";
    var tagPicking = false;
    var propToken = null;
    var toks = root.tokenize(rest);
    for (var i = 0; i < toks.length; i++) {
      var t = toks[i];
      var last = i === toks.length - 1 && open;
      if (t.charAt(0) === "#") {
        var body = t.slice(1);
        if (last) {
          tagToken = body;
          tagPicking = true;
        } else if (body) {
          tags.push(body);
        }
        continue;
      }
      if (t.charAt(0) === ":") {
        var spec = t.slice(1);
        var eq = spec.indexOf("=");
        var pkey = eq >= 0 ? spec.slice(0, eq) : spec;
        var pval = eq >= 0 ? spec.slice(eq + 1) : null;
        if (last) {
          propToken = {
            "key": pkey,
            "value": pval
          };
        } else if (pkey) {
          props.push({
            "key": root.propKey(pkey),
            "value": pval
          });
        }
        continue;
      }
      words.push(t);
    }
    return {
      "vault": vault,
      "token": token,
      "rest": rest,
      "text": words.join(" "),
      "tags": tags,
      "tagToken": tagToken,
      "tagPicking": tagPicking,
      "props": props,
      "propToken": propToken,
      "propPicking": propToken !== null,
      "picking": false
    };
  }

  function vaultRow(vault) {
    var count = 0;
    for (var i = 0; i < root.allItems.length; i++)
      if (root.allItems[i].vault === vault.name)
        count += 1;
    return root.makeRow("󰝰", vault.name, count + (count === 1 ? " note" : " notes") + " \u00b7 " + vault.path, "", "Vault", "", vault.name, [], []);
  }

  // Client-side fuzzy ranking on every keystroke; no per-key process spawn.
  // A leading "@" shows the vault picker and an open "#" the tag picker;
  // otherwise results span every vault, or just the one the @token resolved
  // to, narrowed further to notes carrying every confirmed #tag. With an empty
  // query the first rows pin today's daily note (open or create); any other
  // query keeps the previous behavior plus a create row.
  function filter() {
    var q = root.queryState();
    root.queryInfo = q;
    var wantDaily = root.cfgBool("showDailyNotes", true);
    var wantTemplates = root.cfgBool("showTemplates", false);

    if (q.picking) {
      var picks = root.matchVaults(q.token);
      var vaultRows = [];
      for (var v = 0; v < picks.length; v++)
        vaultRows.push(root.vaultRow(picks[v]));
      root.items = vaultRows;
      root.rebuildDisplay();
      return;
    }

    var pool = root.allItems;
    if (q.vault)
      pool = pool.filter(function (row) {
          return row.vault === q.vault.name;
        });
    if (q.tags.length > 0)
      pool = pool.filter(function (row) {
          return root.rowHasAllTags(row, q.tags);
        });
    if (q.props.length > 0)
      pool = pool.filter(function (row) {
          return root.rowHasAllProps(row, q.props);
        });

    if (q.propPicking) {
      // A key still being typed lists keys; once "=" is there the same picker
      // switches to that key's values, which is the ":author" drill-down.
      var vaultName = q.vault ? q.vault.name : "";
      var propRows = [];
      var entries;
      if (q.propToken.value === null) {
        entries = root.matchProps(q.propToken.key, pool, "");
        for (var pk = 0; pk < entries.length; pk++)
          propRows.push(root.propKeyRow(entries[pk], vaultName));
      } else {
        var key = root.propKey(q.propToken.key);
        entries = root.matchProps(q.propToken.value, pool, key);
        for (var pv = 0; pv < entries.length; pv++)
          propRows.push(root.propValueRow(key, entries[pv], vaultName));
      }
      root.items = propRows;
      root.rebuildDisplay();
      return;
    }

    if (q.tagPicking) {
      var tags = root.matchTags(q.tagToken, pool);
      var tagRows = [];
      for (var t = 0; t < tags.length; t++)
        tagRows.push(root.tagRow(tags[t], q.vault ? q.vault.name : ""));
      root.items = tagRows;
      root.rebuildDisplay();
      return;
    }

    var query = q.text;
    var scope = q.vault ? [q.vault] : root.vaults;
    var shown = [];
    // A tag or property filter is a claim about existing notes, so the daily
    // pin and the create row - neither of which can satisfy it - step aside.
    var scoped = q.tags.length > 0 || q.props.length > 0;
    var pins = scoped ? [] : root.dailyPins(scope);
    if (!query) {
      shown = pins.concat(pool.slice());
    } else {
      shown = FuzzySearch.search(query, pool);
      if (root.matchesDaily(query))
        shown = pins.concat(shown);
      var target = scoped ? null : (q.vault || root.primaryVault());
      var newRel = target ? root.safeNewNoteRel(query) : "";
      if (newRel) {
        var newName = root.safeNameFor(newRel);
        shown.push(root.makeRow("󱘒", "Create new note - " + newName, "Create '" + newRel + "' in " + target.name, "obsidian://new?vault=" + encodeURIComponent(target.obsidianName) + "&name=" + encodeURIComponent(newName), "New Note", newRel, target.name, [], []));
      }
    }
    shown = shown.filter(function (row) {
        if (row.kind === "Daily Note")
          return wantDaily;
        if (row.kind === "Template")
          return wantTemplates;
        return true;
      });
    root.items = shown;
    root.rebuildDisplay();
  }

  // The empty state names the picker that came up empty, so a typo in a tag
  // or a property value reads differently from a search with no hits.
  function emptyText() {
    var q = root.queryInfo;
    if (q.picking)
      return "No vault matching \u201c" + q.token + "\u201d";
    if (q.tagPicking)
      return "No tag matching \u201c" + q.tagToken + "\u201d";
    if (q.propPicking)
      return q.propToken.value === null ? "No property matching \u201c" + q.propToken.key + "\u201d" : "No " + root.propKey(q.propToken.key) + " matching \u201c" + q.propToken.value + "\u201d";
    return root.filterText ? "No matches for \u201c" + root.filterText + "\u201d" : "No notes found";
  }

  function matchesDaily(query) {
    var q = String(query || "").trim().toLowerCase();
    return q.indexOf("daily") !== -1 || q.indexOf("today") !== -1;
  }

  // One pin per daily-enabled vault in scope: a single row when @vault
  // narrowed the search, one per vault otherwise.
  function dailyPins(scope) {
    var pins = [];
    for (var i = 0; i < scope.length; i++)
      if (scope[i].daily)
        pins.push(root.dailyRow(scope[i]));
    return pins;
  }

  function dailyRow(vault) {
    return root.makeRow("", "Today's daily note", "Open in " + vault.name, "obsidian://daily?vault=" + encodeURIComponent(vault.obsidianName), "Daily Pin", "", vault.name, [], []);
  }


  function rebuildDisplay() {
    displayModel.clear();
    for (var j = 0; j < root.items.length; j++)
      displayModel.append(root.items[j]);
    if (displayModel.count === 0)
      selectedIndex = 0;
    else if (selectedIndex >= displayModel.count)
      selectedIndex = displayModel.count - 1;
    else if (selectedIndex < 0)
      selectedIndex = 0;
    Qt.callLater(function () {
        if (displayModel.count > 0)
          resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
      });
  }

  function select(delta) {
    if (displayModel.count === 0)
      return;
    root.disarmPointer();
    if (!cursorActive) {
      cursorActive = true;
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0;
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count;
    }
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain);
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter;
    root.selectedIndex = 0;
    root.cursorActive = true;
    root.disarmPointer();
    root.filter();
  }

  function disarmPointer() {
    pointerGate.reset();
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse))
      return;
    root.cursorActive = true;
    root.selectedIndex = index;
  }

  // Raw queries must never become paths. Subfolders ("a/b") stay allowed,
  // everything else that could escape the vault yields no create row.
  function isSafeRel(rel) {
    var s = String(rel || "");
    if (!s || s.length > 220 || s.charAt(0) === "/")
      return false;
    if (s.indexOf("\0") !== -1 || s.indexOf("\n") !== -1 || s.indexOf("\r") !== -1 || s.indexOf("\t") !== -1)
      return false;
    var parts = s.split("/");
    for (var i = 0; i < parts.length; i++) {
      var seg = parts[i];
      if (!seg || seg === "." || seg === ".." || seg.length > 100)
        return false;
    }
    return true;
  }

  function safeNewNoteRel(query) {
    var q = String(query || "").trim();
    if (!q || q.length > 200 || q.charAt(0) === "/")
      return "";
    var rel = q.slice(-3).toLowerCase() === ".md" ? q : q + ".md";
    return root.isSafeRel(rel) ? rel : "";
  }

  function safeNameFor(rel) {
    var s = String(rel || "");
    return s.slice(-3).toLowerCase() === ".md" ? s.slice(0, -3) : s;
  }

  // Rows carry their own vault, so a result opened from an unscoped search
  // still resolves against the vault it actually came from.
  function vaultBaseFor(name) {
    var vault = root.vaultByName(name);
    if (!vault)
      vault = root.primaryVault();
    if (!vault || vault.path.charAt(0) !== "/")
      return "";
    return vault.path.replace(/\/$/, "");
  }

  function absPathForRow(row) {
    var rel = row.rel;
    if (!root.isSafeRel(rel))
      return "";
    var base = root.vaultBaseFor(row.vault);
    if (!base)
      return "";
    return base + "/" + String(rel);
  }

  function launchArgvFor(mode, row) {
    if (mode === "obsidian")
      return ["obsidian", row.action];
    var kind = row.kind || "Note";
    var forcedObsidian = kind === "Canvas" || kind === "Base" || kind === "Daily Note" || kind === "Daily Pin" || kind === "Template";
    var opener = mode === "omawrite" ? "omawrite" : mode === "neovim" ? "nvim" : root.cfg("opener", "") || "obsidian";
    var lowered = String(opener).toLowerCase();
    if (!forcedObsidian) {
      var abs = root.absPathForRow(row);
      if (!abs)
        return [];
      if (lowered === "omawrite")
        return ["omawrite", abs];
      if (lowered === "neovim" || lowered === "nvim" || lowered === "vim")
        return ["omarchy", "launch", "tui", "--app-id=nvim-obsidian", "nvim", abs];
      if (lowered !== "obsidian")
        return [String(opener), abs];
    }
    return ["obsidian", row.action];
  }

  function activateIndex(index, mode) {
    if (index < 0 || index >= displayModel.count)
      return;
    var row = displayModel.get(index);
    var kind = row.kind || "Note";
    // Picking a vault rewrites the query into a scoped one instead of
    // launching anything; the trailing space closes the @token.
    if (kind === "Vault") {
      root.setFilter("@" + row.vault + " ");
      return;
    }
    // Same for a tag: the picked tag replaces the token still being typed.
    if (kind === "Tag") {
      root.setFilter(root.withoutOpenToken() + row.label + " ");
      return;
    }
    // Picking a property key leaves ":key=" open so its values list straight
    // away; picking a value closes the token and applies the filter.
    if (kind === "PropKey") {
      root.setFilter(root.withoutOpenToken() + row.label + "=");
      return;
    }
    if (kind === "PropValue") {
      root.setFilter(root.withoutOpenToken() + root.propText(row.rel, row.label) + " ");
      return;
    }
    var argv = root.launchArgvFor(mode || "", row);
    if (!argv || argv.length === 0)
      return;
    var needsFile = kind === "New Note" && argv[0] !== "obsidian";
    root.opened = false;
    if (needsFile) {
      var base = root.vaultBaseFor(row.vault);
      var rel = String(row.rel || "");
      if (!base || !root.isSafeRel(rel))
        return;
      if (ensureProc.running)
        return;
      root.pendingLaunch = argv;
      root.hasPendingLaunch = true;
      ensureProc.collected = "";
      ensureProc.command = [root.ensureScript, base, rel];
      ensureProc.running = true;
      return;
    }
    Util.execArgv(argv);
  }

  ListModel {
    id: displayModel
  }

  Process {
    id: searchProc
    property string collected: ""
    property int serial: 0
    stdout: SplitParser {
      onRead: function (data) {
        searchProc.collected += data + "\n";
      }
    }
    onExited: {
      if (searchProc.serial !== root.searchSerial)
        return;
      root.allItems = root.parseResults(searchProc.collected);
      root.filter();
      if (root.searchPending) {
        root.searchPending = false;
        root.runSearch();
      }
    }
  }

  // ensure-note.sh proves the canonical destination stays beneath the
  // canonical vault root before mkdir/touch. Launch only on its success.
  Process {
    id: ensureProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function (data) {
        ensureProc.collected += data + "\n";
      }
    }
    onExited: function (exitCode) {
      var output = String(ensureProc.collected || "").trim();
      ensureProc.collected = "";
      if (!root.hasPendingLaunch)
        return;
      root.hasPendingLaunch = false;
      if (exitCode !== 0 || !output)
        return;
      launchProc.command = root.pendingLaunch;
      launchProc.running = true;
    }
  }

  Process {
    id: launchProc
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }
    color: "transparent"
    WlrLayershell.namespace: "obsidian-focused-search"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: Math.min(root.cardHeight, panel.height - Style.gapsOut * 2)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea {
        anchors.fill: parent
        onClicked: {
        }
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Escape) {
            // Escape peels one layer at a time: query, then @vault scope,
            // then the menu itself.
            var esc = root.queryState();
            if (esc.picking || esc.tagPicking || esc.propPicking)
              root.setFilter(root.withoutOpenToken());
            else if (esc.text)
              root.setFilter(root.scopePrefix(esc.vault, esc.tags, esc.props));
            else if (esc.props.length > 0)
              root.setFilter(root.scopePrefix(esc.vault, esc.tags, esc.props.slice(0, -1)));
            else if (esc.tags.length > 0)
              root.setFilter(root.scopePrefix(esc.vault, esc.tags.slice(0, -1), []));
            else if (root.filterText)
              root.setFilter("");
            else
              root.close();
            event.accepted = true;
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText));
            event.accepted = true;
          } else if (event.key === Qt.Key_Up) {
            root.select(-1);
            event.accepted = true;
          } else if (event.key === Qt.Key_Down) {
            root.select(1);
            event.accepted = true;
          } else if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_K || event.key === Qt.Key_P)) {
            root.select(-1);
            event.accepted = true;
          } else if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_J || event.key === Qt.Key_N)) {
            root.select(1);
            event.accepted = true;
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-6);
            event.accepted = true;
          } else if (event.key === Qt.Key_PageDown) {
            root.select(6);
            event.accepted = true;
          } else if ((event.modifiers & Qt.AltModifier) && event.key === Qt.Key_O) {
            if (root.cursorActive)
              root.activateIndex(root.selectedIndex, "obsidian");
            else if (displayModel.count > 0)
              root.cursorActive = true;
            event.accepted = true;
          } else if ((event.modifiers & Qt.AltModifier) && event.key === Qt.Key_W) {
            if (root.cursorActive)
              root.activateIndex(root.selectedIndex, "omawrite");
            else if (displayModel.count > 0)
              root.cursorActive = true;
            event.accepted = true;
          } else if ((event.modifiers & Qt.AltModifier) && event.key === Qt.Key_N) {
            if (root.cursorActive)
              root.activateIndex(root.selectedIndex, "neovim");
            else if (displayModel.count > 0)
              root.cursorActive = true;
            event.accepted = true;
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Right) {
            if (root.cursorActive)
              root.activateIndex(root.selectedIndex);
            else if (displayModel.count > 0)
              root.cursorActive = true;
            event.accepted = true;
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
            root.setFilter(root.filterText + event.text);
            event.accepted = true;
          }
        }

        Column {
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          spacing: root.contentSpacing

          Rectangle {
            width: parent.width
            height: root.headerHeight
            radius: root.cornerRadius
            color: "transparent"

            Text {
              id: scopeLabel
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.scopeText
              visible: text.length > 0
              color: root.queryInfo.vault || root.queryInfo.tags.length > 0 || root.queryInfo.props.length > 0 ? root.selectedText : root.foreground
              opacity: root.queryInfo.vault || root.queryInfo.tags.length > 0 || root.queryInfo.props.length > 0 ? 0.9 : 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              anchors.left: parent.left
              anchors.right: scopeLabel.visible ? scopeLabel.left : parent.right
              anchors.rightMargin: scopeLabel.visible ? Style.space(10) : 0
              anchors.verticalCenter: parent.verticalCenter
              text: root.filterText || "Search notes…  (@vault, #tag, :prop)"
              color: root.foreground
              opacity: root.filterText ? 1 : 0.58
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              elide: Text.ElideRight
            }
          }

          Item {
            width: parent.width
            height: root.cardHeight - root.contentMargin * 2 - root.headerHeight - root.contentSpacing

            ListView {
              id: resultList
              anchors.fill: parent
              model: displayModel
              clip: true
              spacing: Style.space(4)
              boundsBehavior: Flickable.StopAtBounds

              delegate: BorderSurface {
                id: row
                required property int index
                required property string icon
                required property string label
                required property string detail

                readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

                width: ListView.view.width
                height: root.rowHeight
                radius: root.cornerRadius
                color: hasCursor ? root.selectedBackground : "transparent"
                borderSpec: hasCursor ? Border.surfaceSpec("menu", "selected-border", root.selectedText, 0) : Border.none()

                Text {
                  text: row.icon
                  color: row.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(46)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: row.label
                    color: row.hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: row.detail
                    visible: row.detail.length > 0
                    color: row.hasCursor ? root.selectedText : root.foreground
                    opacity: 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: function (mouse) {
                    root.selectFromPointer(row.index, row, mouse);
                  }
                  onClicked: {
                    root.cursorActive = true;
                    root.selectedIndex = row.index;
                    root.activateIndex(row.index);
                  }
                }
              }
            }

            Column {
              anchors.centerIn: parent
              spacing: Style.space(8)
              visible: displayModel.count === 0 && !searchProc.running

              Text {
                text: "󰠮"
                color: root.selectedText
                opacity: 0.8
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
              }

              Text {
                text: root.emptyText()
                color: root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
              }
            }
          }
        }
      }
    }
  }
}
