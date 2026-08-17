import QtQuick
import QtTest

TestCase {
  id: testCase
  name: "SubwaveMark"

  function test_loadsBrandedArtworkAtCompactSize() {
    var component = Qt.createComponent("../SubwaveMark.qml")
    tryCompare(component, "status", Component.Ready)

    var mark = component.createObject(testCase, { width: 20, height: 20 })
    verify(mark !== null)
    tryCompare(mark, "status", Image.Ready)
    compare(mark.width, 20)
    compare(mark.height, 20)
    verify(mark.paintedWidth > 0)
    verify(mark.paintedHeight > 0)
    mark.destroy()
  }
}
