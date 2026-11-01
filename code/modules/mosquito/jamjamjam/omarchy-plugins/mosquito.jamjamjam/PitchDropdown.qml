// ─────────────────────────────────────────────────────────────────────────────
// Taken verbatim from Pitchfork (plugins/io.github.kemezz.pitchfork):
//   PitchDropdown.qml
//   MIT License, Copyright (c) 2026 Hyeongjin
//
// It is copied rather than rewritten because its popup height policy IS the fix
// it documents (see the note below): the kit's Dropdown sizes the popup to its
// rows and then subtracts border and padding from that, so its list is always a
// few pixels short of its content and scrolls by exactly that sliver. Rewriting
// it would re-introduce the bug it exists to avoid.
// ─────────────────────────────────────────────────────────────────────────────

// A single-select dropdown, painted with the kit's control chrome but with its
// own popup height policy.
// The kit's own Dropdown sets the popup's total height to the height its rows
// need, and the popup then subtracts its border and padding from that to size
// the list -- so the list is always a few pixels shorter than its content and
// every menu scrolls by exactly that sliver. A list that can be dragged two
// pixels reads as broken rather than as scrollable, which is the reason this
// component exists.
// The policy here is: size the popup's *content* box, and give it either the
// whole list or a half-row of the next one.
//   rows <= maxVisibleRows   the exact height of the rows, and the list is
//                            made non-interactive, so it cannot move at all
//   rows >  maxVisibleRows   one row short of the cap plus half of the next,
//                            so the cut-off row is itself the affordance

import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// `options` takes { value, label } rows, which is the shape Tunings.js
// already produces. Keyboard handling matches the kit so the panel's own
// cursor rules still apply: Enter or Space opens, Esc closes, j/k or the
// arrows walk, Enter selects.
Item {
    id: root

    property string label: ""
    // Input only: the component never writes it. See selectCurrent below.
    property string value: ""
    property var options: []
    property color foreground: Color.popups.text
    property color background: Color.popups.background
    property color popupBorder: Color.popups.border
    property color accent: Color.accent
    property string fontFamily: Style.font.family
    property int rowHeight: Style.spacing.controlHeight
    property int popupRowHeight: Style.spacing.popupRowHeight
    property int rowSpacing: Style.spacing.labelGap
    // How many rows may be shown in full. Nine or more inputs is where the
    // half-row peek starts; below that every menu fits exactly.
    property int maxVisibleRows: 8
    // Panel-cursor flag, as on the kit's controls: a panel that runs its own
    // keyboard cursor paints the trigger through this rather than through Qt
    // focus.
    property bool hasCursor: false
    readonly property var popupBorderSpec: Border.localOrSurfaceSpec("popups", "border", root.popupBorder, Color.popups.border, Style.normalBorderWidth)
    readonly property bool popupOpen: popup.opened
    readonly property int rowCount: root.options.length
    readonly property bool overflowing: root.rowCount > root.maxVisibleRows
    readonly property real rowStep: root.popupRowHeight + root.rowSpacing
    readonly property real listHeight: root.overflowing ? (root.maxVisibleRows - 1) * root.rowStep + root.popupRowHeight / 2 : Math.max(root.popupRowHeight, root.rowCount * root.rowStep - root.rowSpacing)

    signal changed(string value)
    signal hovered(bool isHovered)

    function open() {
        popup.open();
    }

    function close() {
        popup.close();
    }

    function optionValue(option) {
        return (option && typeof option === "object") ? String(option.value) : String(option);
    }

    function optionLabel(option) {
        return (option && typeof option === "object") ? String(option.label) : String(option);
    }

    function currentLabel() {
        for (var index = 0; index < root.options.length; index++) {
            if (root.optionValue(root.options[index]) === root.value)
                return root.optionLabel(root.options[index]);

        }
        return root.value;
    }

    implicitWidth: Style.spacing.dropdownWidth
    implicitHeight: root.label !== "" ? root.rowHeight + Style.spacing.huge : root.rowHeight

    Column {
        anchors.fill: parent
        spacing: Style.spacing.labelGap

        Text {
            textFormat: Text.PlainText
            visible: root.label !== ""
            text: root.label
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
        }

        BorderSurface {
            id: trigger

            readonly property bool focused: trigger.activeFocus
            readonly property bool hot: triggerHover.hovered || root.hasCursor

            width: parent.width
            height: root.rowHeight
            radius: Style.cornerRadius
            color: Style.controlFill(trigger.focused, trigger.hot, root.foreground, root.accent)
            borderSpec: Border.controlSpec(trigger.focused ? "focus" : (trigger.hot ? "hover-cursor" : "normal"), root.foreground, root.accent)
            activeFocusOnTab: true
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
                    if (popup.opened)
                        popup.close();
                    else
                        popup.open();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Escape && popup.opened) {
                    popup.close();
                    event.accepted = true;
                }
            }

            HoverHandler {
                id: triggerHover

                onHoveredChanged: root.hovered(hovered)
            }

            Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: chevron.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: trigger.borderLeft + Style.spacing.controlPaddingX
                anchors.rightMargin: trigger.borderRight + Style.spacing.md
                text: root.currentLabel()
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
            }

            Text {
                id: chevron

                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: trigger.borderRight + Style.spacing.controlGap
                text: popup.opened ? "󰅃" : "󰅀"
                color: Qt.darker(root.foreground, 1.2)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    trigger.forceActiveFocus();
                    if (popup.opened)
                        popup.close();
                    else
                        popup.open();
                }
            }

            Popup {
                id: popup

                x: 0
                y: trigger.height + Style.spacing.xxs
                width: trigger.width
                // The content box, not the outer height: the padding below is
                // then added on top of it rather than eaten out of it.
                contentHeight: root.listHeight
                padding: Style.spacing.hairline
                leftPadding: Border.left(root.popupBorderSpec) + Style.spacing.hairline
                rightPadding: Border.right(root.popupBorderSpec) + Style.spacing.hairline
                topPadding: Border.top(root.popupBorderSpec) + Style.spacing.hairline
                bottomPadding: Border.bottom(root.popupBorderSpec) + Style.spacing.hairline
                focus: true
                onOpened: {
                    optionList.currentIndex = Math.max(0, optionList.indexOfValue(root.value));
                    optionList.positionViewAtIndex(optionList.currentIndex, ListView.Contain);
                    optionList.forceActiveFocus();
                }

                background: BorderSurface {
                    color: root.background
                    borderSpec: root.popupBorderSpec
                    radius: Style.cornerRadius
                }

                contentItem: ListView {
                    id: optionList

                    function indexOfValue(wanted) {
                        for (var index = 0; index < root.options.length; index++) {
                            if (root.optionValue(root.options[index]) === wanted)
                                return index;

                        }
                        return -1;
                    }

                    // Emits and does not assign. The kit's dropdown writes
                    // the new value onto its own `value` property, which
                    // destroys the caller's binding to it -- and the panel
                    // needs that binding intact, because choosing an
                    // instrument can reset the tuning row underneath it and
                    // the trigger has to follow.
                    function selectCurrent() {
                        if (optionList.currentIndex < 0 || optionList.currentIndex >= root.options.length)
                            return ;

                        root.changed(root.optionValue(root.options[optionList.currentIndex]));
                        popup.close();
                    }

                    spacing: root.rowSpacing
                    model: root.options
                    currentIndex: -1
                    clip: true
                    // A list that fits has nothing to scroll, so it does not
                    // accept a drag or a wheel event either.
                    interactive: root.overflowing
                    boundsBehavior: Flickable.StopAtBounds
                    Keys.priority: Keys.BeforeItem
                    Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Escape) {
                            popup.close();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Down || event.text === "j") {
                            optionList.currentIndex = Math.min(root.options.length - 1, optionList.currentIndex + 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Up || event.text === "k") {
                            optionList.currentIndex = Math.max(0, optionList.currentIndex - 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                            optionList.selectCurrent();
                            event.accepted = true;
                        }
                    }

                    delegate: Rectangle {
                        id: option

                        required property var modelData
                        required property int index
                        readonly property bool onCursor: option.index === optionList.currentIndex
                        readonly property bool isCurrent: root.optionValue(option.modelData) === root.value

                        width: optionList.width
                        height: root.popupRowHeight
                        radius: Style.cornerRadius
                        color: option.onCursor ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"

                        // Which row is in force, shown alongside which row the
                        // cursor is on. The kit's dropdown paints only the
                        // cursor, so an open menu says where you are but not
                        // what you already chose.
                        Text {
                            id: mark

                            textFormat: Text.PlainText
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Style.spacing.controlPaddingX
                            text: option.isCurrent ? "󰄬" : ""
                            color: root.accent
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                        }

                        Text {
                            textFormat: Text.PlainText
                            anchors.left: mark.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Style.spacing.huge
                            anchors.rightMargin: Style.spacing.controlPaddingX
                            text: root.optionLabel(option.modelData)
                            color: option.onCursor ? Style.hoverStateColor(root.foreground, root.accent) : root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            font.bold: option.isCurrent
                            elide: Text.ElideRight
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPositionChanged: optionList.currentIndex = option.index
                            onClicked: optionList.selectCurrent()
                        }

                    }

                }

            }

        }

    }

}
