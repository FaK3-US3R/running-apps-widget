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
//   rev             bumps when any per-app detail changes (focus, count, title)
//   focusedApp      app id of the focused window ("" = none)
//   totalWindows    number of counted windows
//   countOf / titleOf / labelOf / iconSourceOf (id)     per-app lookups
//   toplevelFor(id) the window to preview (focused one, else first) or null
//   tooltipOf(id)   one-line hover text: name, window title, window count
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

    // one line of hover text: "Firefox - Docs (2 windows)"
    function tooltipOf(appId) {
        const name = svc.labelOf(appId);
        if (svc.isGhost(appId)) return name + " - running in the background";
        const title = svc.titleOf(appId);
        const n = svc.countOf(appId);
        let s = name;
        if (title !== "" && title !== name) s += " - " + title;
        if (n > 1) s += " (" + n + " windows)";
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
        } else {
            svc.scheduleWinQuery();
        }
    }

    // ---- learning which processes own which app's windows ----
    function scheduleWinQuery() { winDebounce.restart() }

    function queryWindows() {
        if (!svc.showGhosts || svc._backend === "none") return;
        if (winNiri.running || winHypr.running) return;
        if (svc._backend === "hyprland") winHypr.running = true;
        else winNiri.running = true;    // "niri", or not probed yet: try niri first
    }

    Timer { id: winDebounce; interval: 250; repeat: false; onTriggered: svc.queryWindows() }
    // a slow refresh so the pids stay current for apps that are already open
    Timer {
        interval: 20000
        repeat: true
        running: svc.showGhosts && svc.appIds.length > 0
        onTriggered: svc.queryWindows()
    }

    // turn the compositor's window list into appId -> pids; false if it is not that JSON
    function ingestWindows(text, key) {
        let arr;
        try { arr = JSON.parse(String(text || "")); } catch (e) { return false; }
        if (!Array.isArray(arr)) return false;
        const by = ({});
        for (let i = 0; i < arr.length; i++) {
            const w = arr[i];
            const id = String(w[key] || "");
            const pid = Number(w.pid);
            if (id === "" || !isFinite(pid) || pid <= 0) continue;
            if (!by[id]) by[id] = [];
            if (by[id].indexOf(pid) < 0) by[id].push(pid);
        }
        // replace the pids of every app that has windows now; keep the others'
        const m = Object.assign({}, svc._pidMap);
        for (const id in by) m[id] = by[id];
        svc._pidMap = m;
        return true;
    }

    Process {
        id: winNiri
        command: ["niri", "msg", "--json", "windows"]
        stdout: StdioCollector { id: niriOut }
        onExited: (exitCode, exitStatus) => {
            svc._winExit = exitCode;
            winNiriSettle.restart();
        }
    }
    Timer { id: winNiriSettle; interval: 60; repeat: false; onTriggered: svc.onNiriDone() }
    function onNiriDone() {
        if (svc._winExit === 0 && svc.ingestWindows(niriOut.text, "app_id")) {
            svc._backend = "niri";
        } else if (svc._backend !== "niri") {
            winHypr.running = true;     // not niri: try Hyprland once
        }
    }

    Process {
        id: winHypr
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector { id: hyprOut }
        onExited: (exitCode, exitStatus) => {
            svc._winExit = exitCode;
            winHyprSettle.restart();
        }
    }
    Timer { id: winHyprSettle; interval: 60; repeat: false; onTriggered: svc.onHyprDone() }
    function onHyprDone() {
        if (svc._winExit === 0 && svc.ingestWindows(hyprOut.text, "class")) {
            svc._backend = "hyprland";
        } else if (svc._backend === "") {
            svc._backend = "none";      // neither compositor answers: no ghosts
        }
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

    onPluginApiChanged: svc.refresh()
    Component.onCompleted: svc.refresh()
}
