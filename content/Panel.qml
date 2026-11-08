// running-apps-widget panel: every open app with its focused window's title. Click a
// row to focus that app (cycling its windows when it already has focus). The
// host draws the card; this content is transparent and the host sizes the card
// from implicitHeight. With "Enable thumbnail preview" on, a row also shows a live
// capture of the app's window where the compositor can capture windows.
import QtQuick
import Quickshell.Wayland
import Ryoku.PluginKit
import Ryoku.PluginKit.Singletons

Item {
    id: root

    property var pluginApi
    property string density: "full"
    property real s: 1
    property real widthBudget: 320
    property bool active: false

    readonly property var service: pluginApi ? pluginApi.mainInstance : null
    readonly property var ids: service ? service.displayIds : []
    readonly property int windows: service ? service.totalWindows : 0
    readonly property int ghosts: service ? service.ghostCount : 0

    // previews are on but the compositor delivers no frame: say so
    property bool thumbNote: false
    readonly property bool wantsThumbs: service
        ? (service.showThumbnails && root.visible && root.ids.length > 0) : false
    onWantsThumbsChanged: {
        root.thumbNote = false;
        if (root.wantsThumbs) thumbWaitP.restart();
        else thumbWaitP.stop();
    }
    Timer {
        id: thumbWaitP
        interval: 1500
        repeat: false
        onTriggered: root.thumbNote = !(root.service && root.service.captureSeen)
    }

    implicitWidth: root.widthBudget
    implicitHeight: col.implicitHeight + 6 * root.s

    Column {
        id: col
        width: root.width
        spacing: 9 * root.s

        // ---- eyebrow: identity + how many windows ----
        Item {
            width: root.width
            height: 13 * root.s

            MicroLabel {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                label: "Running Apps"
                s: root.s
            }
            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.windows + (root.windows === 1 ? " window" : " windows")
                      + (root.ghosts > 0 ? "  \u00b7  " + root.ghosts + " in background" : "")
                color: Theme.dim
                font.family: Theme.mono
                font.pixelSize: 11 * root.s
            }
        }

        // ---- hair separator ----
        Rectangle {
            width: root.width
            height: 1
            color: Theme.hair
        }

        // ---- the apps (scrolls when there are many) ----
        Flickable {
            id: flick
            width: root.width
            height: Math.min(list.implicitHeight, 360 * root.s)
            contentWidth: width
            contentHeight: list.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            visible: root.ids.length > 0

            Column {
                id: list
                width: flick.width
                spacing: 2 * root.s

                Repeater {
                    model: root.ids
                    delegate: Item {
                        id: rowI
                        required property string modelData
                        readonly property string appId: modelData
                        readonly property bool focused: root.service
                            ? root.service.focusedApp === rowI.appId : false
                        readonly property int count: {
                            if (!root.service) return 0;
                            void root.service.rev;
                            return root.service.countOf(rowI.appId);
                        }
                        readonly property bool ghost: root.service
                            ? root.service.isGhost(rowI.appId) : false
                        readonly property string title: {
                            if (!root.service) return "";
                            void root.service.rev;
                            return rowI.ghost ? "Running in the background"
                                              : root.service.titleOf(rowI.appId);
                        }
                        readonly property string label: root.service
                            ? root.service.labelOf(rowI.appId) : rowI.appId
                        readonly property string iconSrc: root.service
                            ? root.service.iconSourceOf(rowI.appId) : ""
                        readonly property var capture: {
                            if (!root.service) return null;
                            void root.service.rev;
                            return root.service.toplevelFor(rowI.appId);
                        }
                        readonly property bool thumbWanted: root.service
                            ? (root.service.showThumbnails && root.visible && rowI.capture !== null)
                            : false

                        width: list.width
                        height: 40 * root.s
                        opacity: rowI.ghost ? 0.6 : 1.0

                        Rectangle {
                            anchors.fill: parent
                            radius: 6 * root.s
                            color: rowI.focused
                                ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.12)
                                : rowMa.containsMouse
                                    ? Qt.rgba(Theme.bright.r, Theme.bright.g, Theme.bright.b, 0.08)
                                    : "transparent"
                            Behavior on color { ColorAnimation { duration: Motion.fast } }
                        }

                        Item {
                            id: iconBox
                            x: 8 * root.s
                            anchors.verticalCenter: parent.verticalCenter
                            width: 24 * root.s
                            height: 24 * root.s

                            Image {
                                id: ico
                                anchors.fill: parent
                                source: rowI.iconSrc
                                sourceSize.width: 48 * root.s
                                sourceSize.height: 48 * root.s
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                                asynchronous: true
                                visible: rowI.iconSrc !== "" && status === Image.Ready
                            }
                            Rectangle {
                                visible: !ico.visible
                                anchors.fill: parent
                                radius: 6 * root.s
                                color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                                Text {
                                    anchors.centerIn: parent
                                    text: rowI.label.charAt(0).toUpperCase()
                                    color: Theme.bright
                                    font.family: Theme.mono
                                    font.pixelSize: 12 * root.s
                                    font.weight: Font.Bold
                                }
                            }
                        }

                        Column {
                            anchors.left: iconBox.right
                            anchors.leftMargin: 10 * root.s
                            anchors.right: thumbL.visible ? thumbL.left : meta.left
                            anchors.rightMargin: 8 * root.s
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2 * root.s

                            Text {
                                width: parent.width
                                text: rowI.label
                                elide: Text.ElideRight
                                color: rowI.focused ? Theme.accent : Theme.bright
                                font.family: Theme.font
                                font.pixelSize: 12.5 * root.s
                            }
                            Text {
                                width: parent.width
                                visible: rowI.title !== ""
                                text: rowI.title
                                elide: Text.ElideRight
                                color: Theme.dim
                                font.family: Theme.font
                                font.pixelSize: 10.5 * root.s
                            }
                        }

                        // live window capture: only when enabled, only while the panel is
                        // showing, and only drawn once the compositor delivers a frame
                        Loader {
                            id: thumbL
                            anchors.right: meta.left
                            anchors.rightMargin: 8 * root.s
                            anchors.verticalCenter: parent.verticalCenter
                            active: rowI.thumbWanted
                            visible: item !== null && item.hasContent === true
                            sourceComponent: ScreencopyView {
                                captureSource: rowI.capture
                                live: true
                                paintCursor: false
                                constraintSize: Qt.size(60 * root.s, 34 * root.s)
                                onHasContentChanged: if (hasContent && root.service) root.service.captureSeen = true
                            }
                        }

                        Row {
                            id: meta
                            anchors.right: parent.right
                            anchors.rightMargin: 10 * root.s
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8 * root.s

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: rowI.count > 1
                                text: "\u00d7" + rowI.count
                                color: Theme.dim
                                font.family: Theme.mono
                                font.pixelSize: 11 * root.s
                            }
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 6 * root.s
                                height: width
                                radius: width / 2
                                color: (rowI.focused && !rowI.ghost) ? Theme.accent : "transparent"
                                border.width: rowI.ghost ? 1 : 0
                                border.color: Theme.dim
                            }
                        }

                        MouseArea {
                            id: rowMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (!root.service) return;
                                if (rowI.ghost) root.service.launchApp(rowI.appId);
                                else root.service.activateApp(rowI.appId);
                                if (root.pluginApi) root.pluginApi.closePanel();
                            }
                        }
                    }
                }
            }
        }

        // ---- previews on, but the compositor cannot capture windows ----
        Text {
            width: root.width
            visible: root.thumbNote
            text: "Window previews are on, but this compositor cannot capture windows."
            wrapMode: Text.Wrap
            color: Theme.faint
            font.family: Theme.font
            font.pixelSize: 10 * root.s
        }

        // ---- empty state ----
        Item {
            width: root.width
            height: 70 * root.s
            visible: root.ids.length === 0

            Text {
                anchors.centerIn: parent
                text: "No apps open"
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: 12.5 * root.s
            }
        }
    }
}
