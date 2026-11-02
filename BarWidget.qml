import QtQuick
import qs.Ui

// Bar button: left click toggles the Savanna grid.
BarWidget {
  id: root
  moduleName: "x99.savanna"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰀻"
    onPressed: function(button) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle x99.savanna '{}'")
    }
  }
}
