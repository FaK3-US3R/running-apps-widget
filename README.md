# Running Apps Widget

A Ryoku shell plugin (`running-apps-widget`) for the `topbarGlyph` host. It shows one
icon for every app you have open, lights the focused app, and opens a panel that
lists them all.

## What it does

- **Service** (`service/Main.qml`): the logic, no UI. Reads the open windows,
  groups them by app, keeps a stable order (an app keeps its place until its last
  window closes), resolves names and icons, and focuses an app on request.
- **Widget** (`content/Widget.qml`): the bar glyph. One icon per app, a pill under
  the focused app, one dot per window under the others, and a `+N` chip when the
  apps do not all fit. It hides itself when no app is open (see the note below).
  Hovering an icon opens a small card with the app name, its window title and its
  window count, and optionally a live thumbnail of the window. An app whose last
  window is closed but whose process still runs (a chat app that closes to the
  tray, say) stays as a faded, breathing **ghost** with a hollow ring instead of the
  running dot.
- **Panel** (`content/Panel.qml`): every open app with its window title. Opens
  beneath the glyph.

### Using it

| Action | Result |
| ------ | ------ |
| Left click an icon | Focus that app; if it already has focus, cycle to its next window |
| Hover an icon | After a short delay, a card with the app name, window title and window count |
| Click a ghost icon, or its row in the panel | Open that app again through its own launcher |
| Right click an icon, or click `+N` | Open the panel |
| Click a row in the panel | Focus that app and close the panel |

## What it reads and writes

- **Reads:** the list of open windows (app id, title, focused and minimised state)
  through the Wayland toplevel protocol (`Quickshell.Wayland`), and the installed
  desktop entries (`Quickshell` `DesktopEntries`) to find each app's name and icon.
  Settings are read through `pluginApi.pluginSettings` behind a default.
- **Which process owns each window (for ghosts):** while an app has windows, the
  compositor is asked for each window's process id with `niri msg --json windows`
  (or `hyprctl clients -j` on Hyprland). When an app's last window closes and a short
  grace period passes, `ps -o pid=,stat= -p <pids>` checks whether those same
  processes are still alive. All of it is read-only.
- **Window thumbnails (opt-in, off by default):** only when "Enable thumbnail
  preview" is on, the plugin asks the compositor for a live capture of an app's
  window through `Quickshell.Wayland` (`ScreencopyView`). The capture runs only
  while the hover card or the panel is showing, is drawn on screen and is never
  stored or sent anywhere.
- **Writes:** nothing. No files, no settings except the ones you change in
  Add-ons.
- **Runs:** the three read-only commands above (`niri`, `hyprctl`, `ps`), all
  declared in `dependencies.commands`. Clicking a ghost runs that app's own
  desktop-entry launcher (`DesktopEntry.execute()`), the same as starting it from
  a menu. No network, no privileged actions.

## Settings

| key            | type   | default | description                              |
| -------------- | ------ | ------- | ---------------------------------------- |
| maxIcons       | int    | 8       | Most icons shown on the bar (1 to 12)    |
| showIndicators | toggle | true    | Show a running indicator under each icon |
| showThumbnails | toggle | false   | Enable thumbnail preview on hover and in the panel |
| showGhosts     | toggle | true    | Show faded ghosts for apps running without a window |

The bar also limits the icons to the width it gives the widget; apps that do not
fit are reachable from the `+N` chip and the panel.

## Limits

- **Thumbnails need compositor support.** A window can only be captured when the
  compositor offers a window-capture protocol (for example Hyprland's toplevel
  export). Where it does not, as on Niri at the time of writing, the setting does
  nothing visible: the hover card and the panel show text only, exactly as Ryoku's
  own dock preview falls back to the icon. When previews are on and no frame
  arrives, the hover card and the panel say so instead of failing silently.
  Nothing breaks and nothing is captured that is not shown.
- **Ghosts are a best effort.** They rely on the compositor reporting each window's
  process id, so they work on Niri and Hyprland and are off elsewhere. An app is
  only judged after it had a window in the current shell session, and the check
  follows the process that owned the window. An app that hands its windows to a
  different process before closing, or whose process stays alive for another
  reason, can be shown as a ghost or missed. A ghost disappears when its process
  ends or a window returns, and a short grace period stops an app that is merely
  quitting from flashing as a ghost.
- **Hiding leaves a small gap.** With no app open the widget reports a size of 0 and
  hides, but the bar still gives every plugin slot its own padding (about 13 px),
  so a blank gap remains. A plugin cannot remove its slot from the bar; to remove
  the gap, turn the widget off in QS Bar Settings.

## Preview

Capture a real screenshot of the widget and save it as
`assets/preview-widget.png`, then list it under `files` in `manifest.json`. The
store shows it in the catalogue.

## Build, check, install

```
ryoku plugin validate .
ryoku plugin add . --yes
```

Enable and place it under **Ryoku Settings > Add-ons**. A bar plugin can instead
use `ryoku plugin add . --bar --yes` to enable it on the current bar immediately.

## Author

fake-user: this plugin is community-made (`official` is false).
