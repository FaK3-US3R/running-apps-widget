// running-apps-widget - which apps are open, tracked from the Wayland toplevel protocol.
//
// service/Main.qml is the plugin's logic and carries no UI. It reads the open
// windows through Quickshell.Wayland ToplevelManager (the same compositor-
// neutral source the apptime plugin uses), groups them by app id, keeps a stable
// left-to-right order (an app keeps its place until its last window closes),
// resolves names and icons through the desktop entries, and focuses an app on
// request (cycling its windows when it is already focused).
//
// The glyph and the panel read this state through pluginApi.mainInstance:
//   appIds          unique app ids, stable order        (changes when the set changes)
//   rev             bumps when any per-app detail changes (focus, count, title, monitor)
//   focusedApp      app id of the focused window ("" = none)
//   totalWindows    number of counted windows
//   countOf / titleOf / labelOf / iconSourceOf (id)     per-app lookups
//   toplevelFor(id) the window to preview (focused one, else first) or null
//   monitorOf(id)   monitor/output name for the app's representative window ("" = unknown)
//   indicatorColorFor(id) color for the app's running indicator (monitor-aware when enabled)
//   tooltipOf(id)   one-line hover text: name, window title, window count
//   monitors        detected monitors in order [{name, index}] (index is 1-based slot)
//   monitorCount    number of detected monitors
//   monitorColorAt(i) configured hex color for 1-based monitor slot i
//   showThumbnails  opt-in live window preview (needs compositor support)
//   captureSeen     true once any window capture has delivered a frame
//   ghostIds        apps whose last window is closed but whose process still runs
//   displayIds      appIds followed by ghostIds (what the views list)
//   isGhost(id) / launchApp(id)   ghost lookup; reopen an app through its launcher
//   activateApp(id) focus the app
//
// Ghosts: Wayland only lists windows, so it cannot say that an app is still
// running without one. The compositor can: `niri msg --json windows` (or
// `hyprctl clients -j`) reports each window's process id. While an app has
// windows its pids are remembered; when the last window closes and a short
// grace period passes, `ps` checks whether those same processes are alive. If so
// the app stays as a ghost until the process ends or a window comes back.
// The same compositor queries also supply each window's monitor (niri: workspace_id
// mapped via workspaces to output; hyprland: monitor id mapped via monitors).
// Everything here is read-only: the only action is launchApp, on a click.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Item {
    id: svc

    // set by the host after this file loads
    property var pluginApi

    readonly property var settings: pluginApi ? pluginApi.pluginSettings : null

    property var appIds: []
    property int rev: 0
    property string focusedApp: ""
    property int totalWindows: 0

    property string _idsSig: ""
    property string _sig: ""

    // ---- settings (undefined until the user changes them: use the defaults) ----
    readonly property int maxIcons: {
        const v = svc.settings ? svc.settings.maxIcons : undefined;
        const n = (v === undefined || v === null) ? 8 : parseInt(v, 10);
        return Math.max(1, Math.min(12, isNaN(n) ? 8 : n));
    }
    readonly property bool showIndicators: {
        const v = svc.settings ? svc.settings.showIndicators : undefined;
        return (v === undefined || v === null) ? true : !!v;
    }
    // opt-in: color the running indicator by the monitor the app is on
    readonly property bool useMonitorColors: {
        const v = svc.settings ? svc.settings.useMonitorColors : undefined;
        return (v === undefined || v === null) ? true : !!v;
    }
    // opt-in: a live capture of the window in the hover card and the panel
    readonly property bool showThumbnails: {
        const v = svc.settings ? svc.settings.showThumbnails : undefined;
        return (v === undefined || v === null) ? false : !!v;
    }
    // apps that are still running with no window stay as faded ghosts
    readonly property bool showGhosts: {
        const v = svc.settings ? svc.settings.showGhosts : undefined;
        return (v === undefined || v === null) ? true : !!v;
    }
    property int ghostGraceMs: 1500     // wait this long after a close before judging
    property int ghostPollMs: 4000      // how often ghosts are re-checked

    // ---- monitor colors (1-based slots, matching detected monitor order) ----
    readonly property var _monitorColorDefaults: ["#7aa2f7", "#9ece6a", "#e0af68", "#bb9af7", "#f7768e", "#73daca"]
    function _validColor(s, fallback) {
        const t = String(s || "").trim();
        return /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(t) ? t : fallback;
    }
    function monitorColorAt(slot) {
        // slot is 1-based
        const i = Math.max(1, Math.min(6, parseInt(slot, 10) || 1));
        const key = "monitorColor" + i;
        const v = svc.settings ? svc.settings[key] : undefined;
        return svc._validColor(v, svc._monitorColorDefaults[i - 1] || "#7aa2f7");
    }

    // ---- monitors ----
    property var monitors: []           // [{name, index}] in detected order, index 1-based
    property string _monSig: ""
    readonly property int monitorCount: svc.monitors.length

    // appId -> monitor name for its representative window
    property var _appMon: ({})
    // appId -> [{title, monitor, focused}] from compositor window data
    property var _appMonWins: ({})
    property var _wsToOutput: ({})      // niri: workspace id -> output name
    property var _hyprMonById: ({})     // hyprland: monitor id -> name
    property int _monQuerySerial: 0

    // set by any window capture that delivers a frame; tells the views the
    // compositor can capture windows at all
    property bool captureSeen: false

    // ---- windows ----
    readonly property var windows: ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    onWindowsChanged: svc.refresh()

    // the focused app id, read from the activated toplevel (re-evaluates on a
    // focus change and on a window closing, like apptime's)
    readonly property string focusedAppId: {
        const tls = svc.windows;
        for (let i = 0; i < tls.length; i++) {
            const t = tls[i];
            if (t && t.activated === true)
                return String(t.appId || "");
        }
        return "";
    }
    onFocusedAppIdChanged: svc.refresh()

    // surfaces that are not "apps you have open"
    function excluded(app) {
        const c = String(app || "").toLowerCase();
        return c === ""
            || c.indexOf("org.quickshell") === 0
            || c.indexOf("xdg-desktop-portal") === 0;
    }

    function windowsOf(appId) {
        const out = [];
        const wins = svc.windows;
        for (let i = 0; i < wins.length; i++) {
            const t = wins[i];
            if (t && String(t.appId || "") === appId) out.push(t);
        }
        return out;
    }

    function countOf(appId) { return svc.windowsOf(appId).length }

    function clip(s) {
        const t = String(s || "");
        return t.length > 64 ? t.substring(0, 63) + "\u2026" : t;
    }

    // the focused window's title if the app has focus, else its first window's
    function titleOf(appId) {
        const ws = svc.windowsOf(appId);
        let first = "";
        for (let i = 0; i < ws.length; i++) {
            if (ws[i].activated === true) return svc.clip(ws[i].title);
            if (first === "") first = String(ws[i].title || "");
        }
        return svc.clip(first);
    }

    // the window to preview: the app's focused window, else its first (null = none)
    function toplevelFor(appId) {
        const ws = svc.windowsOf(appId);
        for (let i = 0; i < ws.length; i++)
            if (ws[i].activated === true) return ws[i];
        return ws.length > 0 ? ws[0] : null;
    }

    function monitorOf(appId) {
        const id = String(appId || "");
        if (id === "") return "";
        // prefer the representative window's title match (focused, else first)
        const rep = svc.toplevelFor(id);
        const repTitle = rep ? String(rep.title || "") : "";
        const wins = (svc._appMonWins && svc._appMonWins[id]) ? svc._appMonWins[id] : [];
        if (repTitle !== "") {
            for (let i = 0; i < wins.length; i++)
                if (String(wins[i].title || "") === repTitle && wins[i].monitor)
                    return String(wins[i].monitor);
        }
        if (rep && rep.activated === true) {
            for (let i = 0; i < wins.length; i++)
                if (wins[i].focused && wins[i].monitor) return String(wins[i].monitor);
        }
        if (wins.length > 0 && wins[0].monitor) return String(wins[0].monitor);
        return (svc._appMon && svc._appMon[id]) ? String(svc._appMon[id]) : "";
    }

    function monitorSlotForName(name) {
        const n = String(name || "");
        if (n === "") return 0;
        const ms = svc.monitors || [];
        for (let i = 0; i < ms.length; i++)
            if (String(ms[i].name || "") === n) return Number(ms[i].index) || (i + 1);
        return 0;
    }

    function indicatorColorFor(appId) {
        // "" means "use the caller's default accent/dim color"
        if (!svc.useMonitorColors) return "";
        const mon = svc.monitorOf(appId);
        const slot = svc.monitorSlotForName(mon);
        if (slot <= 0) return "";
        return svc.monitorColorAt(slot);
    }

    // one line of hover text: "Firefox - Docs (2 windows) [DP-1]"
    function tooltipOf(appId) {
        const name = svc.labelOf(appId);
        if (svc.isGhost(appId)) return name + " - running in the background";
        const title = svc.titleOf(appId);
        const n = svc.countOf(appId);
        let s = name;
        if (title !== "" && title !== name) s += " - " + title;
        if (n > 1) s += " (" + n + " windows)";
        const mon = svc.monitorOf(appId);
        if (mon !== "") s += " [" + mon + "]";
        return s;
    }

    // ---- names and icons ----
    function entryFor(appId) {
        try {
            // reading the model makes bindings that call this re-run once the
            // desktop entries have finished loading
            const dep = DesktopEntries.applications ? DesktopEntries.applications.values : null;
            void dep;
            return DesktopEntries.heuristicLookup(appId);
        } catch (e) {
            return null;
        }
    }

    // "org.mozilla.firefox" -> "Firefox" (fallback when no desktop entry matches)
    function prettyLabel(cls) {
        const s = String(cls || "").trim();
        if (s === "") return "Unknown";
        const GENERIC = ["app", "application", "client", "desktop", "gui",
                         "main", "bin", "binaries", "run", "start", "startup"];
        const parts = s.split(".");
        let last = "";
        for (let i = parts.length - 1; i >= 0; i--) {
            const p = String(parts[i] || "").trim();
            if (p === "" || GENERIC.indexOf(p.toLowerCase()) >= 0) continue;
            last = p;
            break;
        }
        if (last === "") last = parts[parts.length - 1];
        const words = last.split(/[-_]/);
        const out = [];
        for (let i = 0; i < words.length; i++) {
            const w = words[i];
            if (w) out.push(w[0].toUpperCase() + w.slice(1));
        }
        return out.length ? out.join(" ") : s;
    }

    function labelOf(appId) {
        const e = svc.entryFor(appId);
        return (e && e.name) ? String(e.name) : svc.prettyLabel(appId);
    }

    function iconSourceOf(appId) {
        const e = svc.entryFor(appId);
        const name = (e && e.icon) ? String(e.icon) : String(appId || "").toLowerCase();
        if (name === "") return "";
        if (name.charAt(0) === "/") return "file://" + name;
        return "image://icon/" + name;
    }

    // ---- state ----
    function refresh() {
        const wins = svc.windows;
        const seen = ({});
        const sigParts = [];
        let focus = "";
        let total = 0;
        for (let i = 0; i < wins.length; i++) {
            const t = wins[i];
            if (!t) continue;
            const id = String(t.appId || "");
            if (svc.excluded(id)) continue;
            total++;
            seen[id] = (seen[id] || 0) + 1;
            if (t.activated === true) focus = id;
            sigParts.push(id + "|" + (t.activated === true ? 1 : 0) + "|"
                          + (t.minimized === true ? 1 : 0) + "|" + String(t.title || ""));
        }

        // apps that had windows a moment ago and have none now
        const closed = [];
        for (let i = 0; i < svc.appIds.length; i++)
            if (!seen[svc.appIds[i]]) closed.push(svc.appIds[i]);
        if (closed.length > 0) svc.appsClosed(closed);

        // a ghost that got a window again is a normal app again
        if (svc.ghostIds.length > 0) {
            const stillGhosts = svc.ghostIds.filter(id => !seen[id]);
            if (stillGhosts.length !== svc.ghostIds.length) svc.setGhosts(stillGhosts);
        }

        // an app keeps its slot until its last window closes; new apps go last
        const next = [];
        for (let i = 0; i < svc.appIds.length; i++)
            if (seen[svc.appIds[i]]) next.push(svc.appIds[i]);
        for (const id in seen)
            if (next.indexOf(id) < 0) next.push(id);

        const idsSig = next.join("\n");
        if (idsSig !== svc._idsSig) {
            svc._idsSig = idsSig;
            svc.appIds = next;
            svc.scheduleWinQuery();     // new app or a closed one: learn pids again
        }
        const sig = sigParts.join("\n");
        if (sig !== svc._sig) {
            svc._sig = sig;
            svc.rev = svc.rev + 1;
        }
        if (focus !== svc.focusedApp) svc.focusedApp = focus;
        if (total !== svc.totalWindows) {
            svc.totalWindows = total;
            svc.scheduleWinQuery();     // a window opened or closed
        }
    }

    // ------------------------------------------------------------------
    // ghosts: apps whose last window closed but whose process still runs
    // ------------------------------------------------------------------
    property var ghostIds: []
    property var _pidMap: ({})          // appId -> pids, learned while it had windows
    property var _pending: ({})         // appId -> pids, waiting out the grace period
    property var _ghostPids: ({})       // appId -> pids of the live processes
    property var _aliveFor: []          // appIds the running ps check covers
    property string _ghostSig: ""
    property string _backend: ""        // "niri" | "hyprland" | "none" | "" (not probed)
    property int _winExit: 0
    property int _wsExit: 0
    property int _outExit: 0
    property int _monExit: 0

    readonly property int ghostCount: svc.showGhosts ? svc.ghostIds.length : 0
    readonly property var displayIds: svc.showGhosts ? svc.appIds.concat(svc.ghostIds) : svc.appIds

    function isGhost(appId) { return svc.ghostIds.indexOf(appId) >= 0 }

    // keep the ghosts' order stable and only notify when the set really changes
    function setGhosts(list) {
        const sig = list.join("\n");
        if (sig === svc._ghostSig) return;
        svc._ghostSig = sig;
        svc.ghostIds = list;
        svc.rev = svc.rev + 1;
    }

    onShowGhostsChanged: {
        if (!svc.showGhosts) {
            svc._pending = ({});
            svc._ghostPids = ({});
            svc.setGhosts([]);
        }
        svc.scheduleWinQuery();
    }

    // ---- learning windows, pids, and monitors from the compositor ----
    function scheduleWinQuery() { winDebounce.restart() }

    function queryWindows() {
        if (svc._backend === "none") {
            // still probe once in case backend became available? no, keep simple
            return;
        }
        // monitor data is useful even when showGhosts is off (for indicator colors)
        if (svc._backend === "hyprland") {
            if (!winHypr.running) winHypr.running = true;
            if (!monHypr.running) monHypr.running = true;
        } else {
            // "niri", or not probed yet: try niri first
            if (!winNiri.running) winNiri.running = true;
            if (!wsNiri.running) wsNiri.running = true;
            if (!outNiri.running) outNiri.running = true;
        }
    }

    Timer { id: winDebounce; interval: 250; repeat: false; onTriggered: svc.queryWindows() }
    // refresh window/monitor info periodically; pids stay current for ghosts
    Timer {
        interval: 5000
        repeat: true
        running: svc.pluginApi !== undefined && svc.pluginApi !== null
        onTriggered: svc.queryWindows()
    }

    function _setMonitors(list) {
        const sig = (list || []).map(m => String(m.name || "")).join("\n");
        if (sig === svc._monSig) return;
        svc._monSig = sig;
        svc.monitors = list || [];
        svc.rev = svc.rev + 1;
    }

    function _applyNiriMonitors() {
        // build ordered monitor list from outputs (object keyed by name)
        // keep insertion order not guaranteed; sort by logical.x then name
        if (!svc._niriOutputsRaw) return;
        const out = svc._niriOutputsRaw;
        const names = [];
        for (const k in out) {
            const o = out[k] || ({});
            names.push({
                name: String(o.name || k),
                x: (o.logical && typeof o.logical.x === "number") ? o.logical.x : 0,
                y: (o.logical && typeof o.logical.y === "number") ? o.logical.y : 0
            });
        }
        names.sort((a, b) => (a.x - b.x) || (a.y - b.y) || a.name.localeCompare(b.name));
        svc._setMonitors(names.map((n, i) => ({ name: n.name, index: i + 1 })));
    }

    function _recomputeAppMonitors() {
        const by = svc._appMonWins || ({});
        const m = ({});
        for (const id in by) {
            const ws = by[id] || [];
            if (ws.length === 0) continue;
            let pick = ws[0];
            for (let i = 0; i < ws.length; i++)
                if (ws[i].focused) { pick = ws[i]; break; }
            if (pick && pick.monitor) m[id] = String(pick.monitor);
        }
        svc._appMon = m;
        // bump rev so bindings that read monitorOf/indicatorColorFor re-evaluate
        svc.rev = svc.rev + 1;
    }

    // turn the niri window list into appId -> pids and appId -> monitor info
    property var _niriOutputsRaw: null
    function ingestNiriWindows(text) {
        let arr;
        try { arr = JSON.parse(String(text || "")); } catch (e) { return false; }
        if (!Array.isArray(arr)) return false;
        const byPid = ({});
        const byMon = ({});
        for (let i = 0; i < arr.length; i++) {
            const w = arr[i];
            const id = String(w.app_id || "");
            if (id === "") continue;
            const pid = Number(w.pid);
            if (isFinite(pid) && pid > 0) {
                if (!byPid[id]) byPid[id] = [];
                if (byPid[id].indexOf(pid) < 0) byPid[id].push(pid);
            }
            const wsid = w.workspace_id;
            const mon = (wsid !== undefined && wsid !== null && svc._wsToOutput)
                ? String(svc._wsToOutput[String(wsid)] || "") : "";
            if (!byMon[id]) byMon[id] = [];
            byMon[id].push({ title: String(w.title || ""), monitor: mon, focused: w.is_focused === true });
        }
        const m = Object.assign({}, svc._pidMap);
        for (const id in byPid) m[id] = byPid[id];
        svc._pidMap = m;
        svc._appMonWins = byMon;
        svc._recomputeAppMonitors();
        return true;
    }

    function ingestHyprClients(text) {
        let arr;
        try { arr = JSON.parse(String(text || "")); } catch (e) { return false; }
        if (!Array.isArray(arr)) return false;
        const byPid = ({});
        const byMon = ({});
        for (let i = 0; i < arr.length; i++) {
            const w = arr[i];
            const id = String(w.class || w.initialClass || "");
            if (id === "") continue;
            const pid = Number(w.pid);
            if (isFinite(pid) && pid > 0) {
                if (!byPid[id]) byPid[id] = [];
                if (byPid[id].indexOf(pid) < 0) byPid[id].push(pid);
            }
            let mon = "";
            if (w.monitor !== undefined && w.monitor !== null && svc._hyprMonById)
                mon = String(svc._hyprMonById[String(w.monitor)] || "");
            if (mon === "" && w.monitorName) mon = String(w.monitorName);
            if (!byMon[id]) byMon[id] = [];
            byMon[id].push({ title: String(w.title || ""), monitor: mon, focused: w.focusHistoryID === 0 || w.focused === true });
        }
        const m = Object.assign({}, svc._pidMap);
        for (const id in byPid) m[id] = byPid[id];
        svc._pidMap = m;
        svc._appMonWins = byMon;
        svc._recomputeAppMonitors();
        return true;
    }

    Process {
        id: winNiri
        command: ["niri", "msg", "--json", "windows"]
        stdout: StdioCollector { id: niriOut }
        onExited: (exitCode, exitStatus) => { svc._winExit = exitCode; winNiriSettle.restart(); }
    }
    Timer { id: winNiriSettle; interval: 60; repeat: false; onTriggered: svc.onNiriDone() }
    function onNiriDone() {
        if (svc._winExit === 0 && svc.ingestNiriWindows(niriOut.text)) {
            svc._backend = "niri";
        } else if (svc._backend !== "niri" && svc._backend !== "hyprland") {
            winHypr.running = true;     // not niri: try Hyprland once
            monHypr.running = true;
        } else if (svc._backend === "" || svc._backend === "niri") {
            // parse failure on niri after it worked? keep backend
            if (svc._winExit !== 0 && svc._backend !== "niri") {
                winHypr.running = true; monHypr.running = true;
            }
        }
    }

    Process {
        id: wsNiri
        command: ["niri", "msg", "--json", "workspaces"]
        stdout: StdioCollector { id: wsNiriOut }
        onExited: (exitCode, exitStatus) => { svc._wsExit = exitCode; wsNiriSettle.restart(); }
    }
    Timer { id: wsNiriSettle; interval: 60; repeat: false; onTriggered: svc.onNiriWsDone() }
    function onNiriWsDone() {
        if (svc._wsExit !== 0) return;
        try {
            const arr = JSON.parse(String(wsNiriOut.text || ""));
            if (!Array.isArray(arr)) return;
            const m = ({});
            for (let i = 0; i < arr.length; i++) {
                const w = arr[i];
                if (w && w.id !== undefined) m[String(w.id)] = String(w.output || "");
            }
            svc._wsToOutput = m;
            // re-ingest windows if we have them, to resolve monitor names
            if (niriOut && niriOut.text) svc.ingestNiriWindows(niriOut.text);
        } catch (e) {}
    }

    Process {
        id: outNiri
        command: ["niri", "msg", "--json", "outputs"]
        stdout: StdioCollector { id: outNiriOut }
        onExited: (exitCode, exitStatus) => { svc._outExit = exitCode; outNiriSettle.restart(); }
    }
    Timer { id: outNiriSettle; interval: 60; repeat: false; onTriggered: svc.onNiriOutDone() }
    function onNiriOutDone() {
        if (svc._outExit !== 0) return;
        try {
            const obj = JSON.parse(String(outNiriOut.text || ""));
            if (obj && typeof obj === "object" && !Array.isArray(obj)) {
                svc._niriOutputsRaw = obj;
                svc._applyNiriMonitors();
            }
        } catch (e) {}
    }

    Process {
        id: winHypr
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector { id: hyprOut }
        onExited: (exitCode, exitStatus) => { svc._winExit = exitCode; winHyprSettle.restart(); }
    }
    Timer { id: winHyprSettle; interval: 60; repeat: false; onTriggered: svc.onHyprDone() }
    function onHyprDone() {
        if (svc._winExit === 0 && svc.ingestHyprClients(hyprOut.text)) {
            svc._backend = "hyprland";
        } else if (svc._backend === "" && svc._winExit !== 0) {
            // if niri also failed earlier, we may end up here; don't set none yet if outputs unknown
        }
        if (svc._backend === "" && svc._winExit !== 0 && !winNiri.running) {
            svc._backend = "none";
        }
    }

    Process {
        id: monHypr
        command: ["hyprctl", "monitors", "-j"]
        stdout: StdioCollector { id: monHyprOut }
        onExited: (exitCode, exitStatus) => { svc._monExit = exitCode; monHyprSettle.restart(); }
    }
    Timer { id: monHyprSettle; interval: 60; repeat: false; onTriggered: svc.onHyprMonDone() }
    function onHyprMonDone() {
        if (svc._monExit !== 0) return;
        try {
            const arr = JSON.parse(String(monHyprOut.text || ""));
            if (!Array.isArray(arr)) return;
            const byId = ({});
            const list = [];
            arr.slice().sort((a, b) => (Number(a.x) - Number(b.x)) || (Number(a.y) - Number(b.y)) || Number(a.id) - Number(b.id));
            for (let i = 0; i < arr.length; i++) {
                const m = arr[i];
                const name = String(m.name || "");
                if (m.id !== undefined) byId[String(m.id)] = name;
                list.push({ name: name, index: i + 1, x: Number(m.x)||0, y: Number(m.y)||0, id: m.id });
            }
            list.sort((a, b) => (a.x - b.x) || (a.y - b.y) || a.name.localeCompare(b.name));
            svc._hyprMonById = byId;
            svc._setMonitors(list.map((n, i) => ({ name: n.name, index: i + 1 })));
            if (hyprOut && hyprOut.text) svc.ingestHyprClients(hyprOut.text);
        } catch (e) {}
    }

    // ---- judging whether a closed app is still running ----
    function appsClosed(ids) {
        if (!svc.showGhosts) return;
        const pend = Object.assign({}, svc._pending);
        let any = false;
        for (let i = 0; i < ids.length; i++) {
            const pids = svc._pidMap[ids[i]];
            if (pids && pids.length > 0) { pend[ids[i]] = pids; any = true; }
        }
        if (any) {
            svc._pending = pend;
            graceTimer.restart();
        }
    }

    Timer { id: graceTimer; interval: svc.ghostGraceMs; repeat: false; onTriggered: svc.checkAlive() }
    // ghosts are re-checked on a slow loop so a quit app does not linger
    Timer {
        interval: svc.ghostPollMs
        repeat: true
        running: svc.ghostIds.length > 0
        onTriggered: svc.checkAlive()
    }

    function checkAlive() {
        if (aliveQuery.running) { graceTimer.restart(); return; }
        const ids = svc.ghostIds.slice();
        for (const id in svc._pending)
            if (ids.indexOf(id) < 0) ids.push(id);
        const pids = [];
        for (let i = 0; i < ids.length; i++) {
            const list = svc._pending[ids[i]] || svc._ghostPids[ids[i]] || [];
            for (let j = 0; j < list.length; j++)
                if (pids.indexOf(list[j]) < 0) pids.push(list[j]);
        }
        if (pids.length === 0) return;
        svc._aliveFor = ids;
        aliveQuery.command = ["ps", "-o", "pid=,stat=", "-p", pids.join(",")];
        aliveQuery.running = true;
    }

    Process {
        id: aliveQuery
        stdout: StdioCollector { id: aliveOut }
        onExited: (exitCode, exitStatus) => aliveSettle.restart()
    }
    Timer { id: aliveSettle; interval: 60; repeat: false; onTriggered: svc.onAliveDone() }

    function onAliveDone() {
        // pids that exist and are not zombies
        const alive = ({});
        const lines = String(aliveOut.text || "").split("\n");
        for (let i = 0; i < lines.length; i++) {
            const m = lines[i].trim().match(/^(\d+)\s+(\S+)/);
            if (m && m[2].charAt(0) !== "Z") alive[m[1]] = true;
        }
        const ghosts = [];
        const gp = Object.assign({}, svc._ghostPids);
        const pend = Object.assign({}, svc._pending);
        for (let i = 0; i < svc._aliveFor.length; i++) {
            const id = svc._aliveFor[i];
            const pids = pend[id] || gp[id] || [];
            const live = pids.filter(p => alive[String(p)] === true);
            if (live.length > 0 && svc.appIds.indexOf(id) < 0) {
                ghosts.push(id);
                gp[id] = live;
            } else {
                delete gp[id];
            }
            delete pend[id];
        }
        svc._ghostPids = gp;
        svc._pending = pend;
        svc.setGhosts(ghosts);
    }

    // bring a ghost back: run the app's own launcher (a single-instance app just
    // shows its window again). The only action in this file, and only on a click.
    function launchApp(appId) {
        const e = svc.entryFor(appId);
        if (!e) return false;
        try { e.execute(); return true; } catch (err) { return false; }
    }

    // focus the app; when it already has focus and several windows, go to the next one
    function activateApp(appId) {
        const ws = svc.windowsOf(appId);
        if (ws.length === 0) return;
        let idx = -1;
        for (let i = 0; i < ws.length; i++) {
            if (ws[i].activated === true) { idx = i; break; }
        }
        const target = ws[(idx + 1) % ws.length];
        try { target.activate(); } catch (e) {}
        svc.refresh();
    }

    Timer {
        // a safety net: window titles and minimised state have no change signal
        // wired above, so re-check twice a second (cheap; the sums only change
        // the views when something really differs)
        interval: 500
        repeat: true
        running: svc.pluginApi !== undefined && svc.pluginApi !== null
        onTriggered: svc.refresh()
    }

    onPluginApiChanged: { svc.refresh(); svc.scheduleWinQuery(); }
    Component.onCompleted: { svc.refresh(); svc.scheduleWinQuery(); }
}
