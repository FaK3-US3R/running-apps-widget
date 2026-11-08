// running-apps-widget glyph: one icon per open app, the focused app lit.
//   left click   focus the app (cycles its windows when it already has focus)
//   right click  open the panel with every open app (so does the +N chip)
//   hover        a card with the app name, window title and window count;
//                with "Enable thumbnail preview" on, also a live window capture
//                (only where the compositor can capture windows)
//   no apps      the widget hides itself (see the note on implicitWidth below)
//   ghost        an app whose last window is closed but whose process still runs
//                stays as a faded icon; click it to open the app again
// Nothing here mutates state - the service does all the work.
//
// The per-app cell is an inline delegate on purpose: Ryoku's plugin guide warns
// that an Image inside an inline `component` used as a delegate loads but never
// paints in Quickshell.
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell.Wayland
import Ryoku.PluginKit.Singletons

Item {
    id: root

    property var pluginApi
    property var screen
    property bool active: false
    property string density: "glyph"
    property real s: 1
    property real widthBudget: 0

    readonly property var service: pluginApi ? pluginApi.mainInstance : null
    readonly property var ids: service ? service.displayIds : []
    readonly property bool hasApps: root.ids.length > 0
    readonly property bool indicators: service ? service.showIndicators : true
    readonly property bool thumbnails: service ? service.showThumbnails : false

    readonly property real cellW: 26 * root.s
    readonly property real gap: 2 * root.s
    readonly property real budget: root.widthBudget > 0 ? root.widthBudget : 220

    // icon cells that fit the budget, capped by the "most icons" setting
    readonly property int limit: Math.max(1, Math.min(
        service ? service.maxIcons : 8,
        Math.floor((root.budget + root.gap) / (root.cellW + root.gap))))
    readonly property bool overflow: root.ids.length > root.limit
    readonly property int shownCount: root.overflow ? Math.max(1, root.limit - 1) : root.ids.length
    readonly property var shownIds: root.ids.slice(0, root.shownCount)
    readonly property int hiddenCount: root.ids.length - root.shownCount

    // With no app open the widget reports 0x0 and hides. The bar still gives a
    // plugin slot its own padding (12 px plus 1 px minimum), so a blank gap of
    // about 13 px remains: a plugin cannot remove its slot from the bar.
    implicitWidth: root.hasApps ? row.implicitWidth : 0
    implicitHeight: root.hasApps ? 28 * root.s : 0
    visible: root.hasApps
    Behavior on implicitWidth { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic } }

    function openPanel() { if (root.pluginApi) root.pluginApi.togglePanel() }

    Row {
        id: row
        visible: root.ids.length > 0
        anchors.verticalCenter: parent.verticalCenter
        spacing: root.gap

        Repeater {
            model: root.shownIds

            // one running app
            delegate: Item {
                id: cell
                objectName: "appCell"
                required property string modelData
                readonly property string appId: modelData
                readonly property bool focused: root.service
                    ? root.service.focusedApp === cell.appId : false
                readonly property int count: {
                    if (!root.service) return 0;
                    void root.service.rev;
                    return root.service.countOf(cell.appId);
                }
                readonly property string iconSrc: root.service
                    ? root.service.iconSourceOf(cell.appId) : ""
                readonly property string appLabel: root.service
                    ? root.service.labelOf(cell.appId) : cell.appId
                readonly property string winTitle: {
                    if (!root.service) return "";
                    void root.service.rev;
                    return root.service.titleOf(cell.appId);
                }
                readonly property string tip: root.service
                    ? root.service.tooltipOf(cell.appId) : cell.appId
                readonly property var capture: {
                    if (!root.service) return null;
                    void root.service.rev;
                    return root.service.toplevelFor(cell.appId);
                }
                readonly property string initial: root.service
                    ? root.service.labelOf(cell.appId).charAt(0).toUpperCase() : "?"
                // a ghost: no window, process still running (faded, breathing)
                readonly property bool ghost: root.service ? root.service.isGhost(cell.appId) : false
                property real pulse: 0.45
                property bool thumbMissing: false

                SequentialAnimation on pulse {
                    running: cell.ghost && root.visible
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.62; duration: 1600; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 0.32; duration: 1600; easing.type: Easing.InOutSine }
                }

                // the hover card: shown after a short delay, above or below the
                // bar depending on which half of the screen the bar sits in
                property bool showTip: false
                property bool placeBelow: true
                readonly property var card: hoverCard

                width: root.cellW
                height: 28 * root.s

                // hover / focus plate
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width - 2 * root.s
                    height: 24 * root.s
                    radius: 6 * root.s
                    color: (cell.focused && !cell.ghost)
                        ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.16)
                        : ma.containsMouse
                            ? Qt.rgba(Theme.bright.r, Theme.bright.g, Theme.bright.b, 0.10)
                            : "transparent"
                    Behavior on color { ColorAnimation { duration: Motion.fast } }
                }

                Image {
                    id: ico
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: -1 * root.s
                    width: 18 * root.s
                    height: 18 * root.s
                    source: cell.iconSrc
                    sourceSize.width: 36 * root.s
                    sourceSize.height: 36 * root.s
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    asynchronous: true
                    visible: cell.iconSrc !== "" && status === Image.Ready
                    opacity: cell.ghost ? (ma.containsMouse ? 0.8 : cell.pulse)
                                        : ((cell.focused || ma.containsMouse) ? 1.0 : 0.8)
                    scale: ma.pressed ? 0.9 : 1.0
                    // the ghost look: drained of colour
                    layer.enabled: cell.ghost
                    layer.effect: MultiEffect {
                        saturation: -0.9
                        brightness: -0.05
                    }
                    Behavior on opacity { enabled: !cell.ghost; NumberAnimation { duration: Motion.fast } }
                    Behavior on scale { NumberAnimation { duration: 90 } }
                }

                // when no icon resolves: the app's initial on a tile
                Rectangle {
                    visible: !ico.visible
                    opacity: cell.ghost ? cell.pulse : 1.0
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: -1 * root.s
                    width: 18 * root.s
                    height: 18 * root.s
                    radius: 5 * root.s
                    color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                    Text {
                        anchors.centerIn: parent
                        text: cell.initial
                        color: Theme.bright
                        font.family: Theme.mono
                        font.pixelSize: 11 * root.s
                        font.weight: Font.Bold
                    }
                }

                // running indicator: a pill when focused, one dot per window otherwise
                Row {
                    visible: root.indicators || cell.ghost
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: parent.height - 5 * root.s
                    spacing: 2 * root.s

                    // a ghost shows a hollow ring: alive, but nothing on screen
                    Rectangle {
                        visible: cell.ghost
                        width: 5 * root.s
                        height: 5 * root.s
                        radius: width / 2
                        color: "transparent"
                        border.width: 1
                        border.color: Theme.dim
                    }
                    Rectangle {
                        visible: cell.focused && !cell.ghost
                        width: 12 * root.s
                        height: 3 * root.s
                        radius: 1.5 * root.s
                        color: Theme.accent
                    }
                    Repeater {
                        model: (cell.focused || cell.ghost) ? 0 : Math.min(cell.count, 3)
                        delegate: Rectangle {
                            width: 3 * root.s
                            height: 3 * root.s
                            radius: 1.5 * root.s
                            color: Theme.dim
                        }
                    }
                }

                // hover delay, then pick the side of the bar the card opens on
                Timer {
                    id: tipTimer
                    interval: 350
                    repeat: false
                    onTriggered: {
                        const wh = cell.Window.height > 0 ? cell.Window.height : 1080;
                        cell.placeBelow = cell.mapToItem(null, 0, 0).y < wh / 2;
                        cell.showTip = true;
                    }
                }

                // previews are on but the compositor delivers no frame: say so
                // instead of failing silently
                Timer {
                    id: thumbWait
                    interval: 1500
                    repeat: false
                    onTriggered: cell.thumbMissing = !(root.service && root.service.captureSeen)
                }
                onShowTipChanged: {
                    cell.thumbMissing = false;
                    if (cell.showTip && root.thumbnails && cell.capture !== null) thumbWait.restart();
                    else thumbWait.stop();
                }

                // the hover card (QtQuick.Controls ToolTip resolves inside a plugin)
                ToolTip {
                    id: hoverCard
                    visible: cell.showTip
                    closePolicy: Popup.NoAutoClose
                    x: (cell.width - width) / 2
                    y: cell.placeBelow ? cell.height + 8 * root.s : -height - 8 * root.s
                    padding: 10 * root.s

                    enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Motion.fast } }
                    exit: Transition { NumberAnimation { property: "opacity"; from: 1; to: 0; duration: Motion.fast } }

                    background: Rectangle {
                        radius: 8 * root.s
                        color: Qt.rgba(0.07, 0.07, 0.08, 0.97)
                        border.width: 1
                        border.color: Theme.hair
                    }

                    contentItem: Column {
                        spacing: 6 * root.s

                        // live window capture: only when enabled, only while this card
                        // is showing, and only drawn once the compositor delivers a frame
                        Loader {
                            id: thumbLoader
                            active: root.thumbnails && cell.showTip && cell.capture !== null
                            visible: item !== null && item.hasContent === true
                            sourceComponent: ScreencopyView {
                                captureSource: cell.capture
                                live: true
                                paintCursor: false
                                constraintSize: Qt.size(240 * root.s, 150 * root.s)
                                onHasContentChanged: if (hasContent && root.service) root.service.captureSeen = true
                            }
                        }

                        Text {
                            text: cell.appLabel
                            color: Theme.bright
                            font.family: Theme.font
                            font.pixelSize: 13 * root.s
                            font.weight: Font.Medium
                        }
                        Text {
                            visible: cell.winTitle !== ""
                            width: Math.min(implicitWidth, 260 * root.s)
                            text: cell.winTitle
                            elide: Text.ElideRight
                            color: Theme.dim
                            font.family: Theme.font
                            font.pixelSize: 11 * root.s
                        }
                        Text {
                            visible: cell.count > 1
                            text: cell.count + " windows"
                            color: Theme.dim
                            font.family: Theme.mono
                            font.pixelSize: 10.5 * root.s
                        }
                        Text {
                            visible: cell.ghost
                            text: "Running in the background"
                            color: Theme.dim
                            font.family: Theme.font
                            font.pixelSize: 11 * root.s
                        }
                        Text {
                            visible: cell.ghost
                            text: "Click to open"
                            color: Theme.faint
                            font.family: Theme.font
                            font.pixelSize: 10.5 * root.s
                        }
                        Text {
                            visible: cell.thumbMissing
                            width: 220 * root.s
                            text: "No window preview: this compositor cannot capture windows."
                            wrapMode: Text.Wrap
                            color: Theme.faint
                            font.family: Theme.font
                            font.pixelSize: 10.5 * root.s
                        }
                    }
                }

                MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onEntered: tipTimer.restart()
                    onExited: { tipTimer.stop(); cell.showTip = false; }
                    onClicked: (mouse) => {
                        tipTimer.stop();
                        cell.showTip = false;
                        if (mouse.button === Qt.RightButton) root.openPanel();
                        else if (root.service) {
                            if (cell.ghost) root.service.launchApp(cell.appId);
                            else root.service.activateApp(cell.appId);
                        }
                    }
                }
            }
        }

        // "+N": apps that did not fit; opens the panel
        Item {
            visible: root.overflow
            width: root.cellW
            height: 28 * root.s

            Text {
                anchors.centerIn: parent
                text: "+" + root.hiddenCount
                color: chipMa.containsMouse ? Theme.accent : Theme.dim
                font.family: Theme.mono
                font.pixelSize: 10.5 * root.s
                font.weight: Font.Medium
            }
            MouseArea {
                id: chipMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openPanel()
            }
        }
    }
}
