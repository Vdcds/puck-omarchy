import QtQuick
import qs.Commons

// Puck's face: two tiny eyes and a quiet smile. It stays expressive without
// taking over the whole bar.
Item {
  id: root
  property bool alert: false
  property color eyeWhite: Qt.lighter(Color.foreground, 1.45)
  property color pupil: Color.popups.background
  property real gaze: 0

  implicitWidth: Style.space(28)
  implicitHeight: Style.space(18)

  SequentialAnimation on gaze {
    running: true
    loops: Animation.Infinite
    NumberAnimation { to: -2.2; duration: 1250; easing.type: Easing.InOutSine }
    PauseAnimation { duration: 600 }
    NumberAnimation { to: 2.2; duration: 1550; easing.type: Easing.InOutSine }
    PauseAnimation { duration: 850 }
    NumberAnimation { to: 0; duration: 700; easing.type: Easing.InOutSine }
    PauseAnimation { duration: 1300 }
  }

  Rectangle {
    id: leftEye
    width: Style.space(10)
    height: root.alert ? Style.space(8) : Style.space(7)
    radius: height / 2
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    anchors.verticalCenterOffset: -Style.space(3)
    color: root.eyeWhite
    Rectangle {
      width: Style.space(3)
      height: width
      radius: width / 2
      x: Math.max(Style.space(2), Math.min(parent.width - width - Style.space(2), parent.width / 2 - width / 2 + root.gaze))
      anchors.verticalCenter: parent.verticalCenter
      color: root.pupil
    }
  }

  Rectangle {
    id: rightEye
    width: Style.space(10)
    height: root.alert ? Style.space(8) : Style.space(7)
    radius: height / 2
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.verticalCenterOffset: -Style.space(3)
    color: root.eyeWhite
    Rectangle {
      width: Style.space(3)
      height: width
      radius: width / 2
      x: Math.max(Style.space(2), Math.min(parent.width - width - Style.space(2), parent.width / 2 - width / 2 + root.gaze))
      anchors.verticalCenter: parent.verticalCenter
      color: root.pupil
    }
  }

  // A drawn curve is crisper than a glyph across the terminal fonts users
  // commonly select in Omarchy.
  Canvas {
    id: smile
    width: Style.space(13)
    height: Style.space(6)
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    anchors.topMargin: Style.space(11)
    antialiasing: true
    onPaint: {
      var context = getContext("2d")
      context.clearRect(0, 0, width, height)
      context.strokeStyle = root.eyeWhite
      context.lineWidth = Math.max(1, Style.space(1))
      context.lineCap = "round"
      context.beginPath()
      context.arc(width / 2, 0, Math.max(2, width / 2 - 1), 0.18 * Math.PI, 0.82 * Math.PI, false)
      context.stroke()
    }
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
  }
}
