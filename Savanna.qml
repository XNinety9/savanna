import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import "SavannaModel.js" as Model

// Savanna: a Launchpad-style fullscreen grid of applications.
// Declared as a `menu` plugin so the host injects the app-library facade
// (shell.appLibrary): sorted/filtered entries, icon lookup and launching.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // Host facade when provided; otherwise we read DesktopEntries ourselves.
  readonly property var apps: (shell && shell.appLibrary) ? shell.appLibrary : null
  property var hiddenIds: ({})
  readonly property string pluginId: (manifest && manifest.id) || "x99.savanna"

  // ---- configuration -----------------------------------------------------
  //
  // Layout and effects are settings on our entry in ~/.config/omarchy/shell.json
  // (editable from the shell settings panel through the manifest's schema);
  // defaults come from the manifest too, so they live in one place. Colours
  // are a [savanna] section of shell.toml, like [menu] or [lock]: a theme can
  // ship one and ~/.config/omarchy/shell.toml overrides it.

  property var settings: ({})

  function opt(key) {
    var v = root.settings[key]
    if (v !== undefined && v !== null && v !== "") return v
    var d = root.manifest && root.manifest.barWidget && root.manifest.barWidget.defaults
    return d ? d[key] : undefined
  }

  function optNum(key, low, high, fallback) {
    var n = Number(root.opt(key))
    return isFinite(n) ? Math.max(low, Math.min(high, n)) : fallback
  }

  function optBool(key, fallback) {
    var v = root.opt(key)
    if (v === true || v === "true") return true
    if (v === false || v === "false") return false
    return fallback
  }

  function findEntry(config) {
    var layout = config && config.bar && config.bar.layout
    var lists = layout ? [layout.left, layout.center, layout.right] : []
    lists.push(config && config.plugins)
    for (var i = 0; i < lists.length; i++) {
      var list = lists[i] || []
      for (var j = 0; j < list.length; j++)
        if (list[j] && list[j].id === root.pluginId) return list[j]
    }
    return {}
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.settings = root.findEntry(JSON.parse(text())) }
      catch (e) { console.warn("savanna: cannot read shell.json:", e) }
    }
  }

  readonly property int columns: Math.round(optNum("columns", 3, 12, 7))
  readonly property int rows: Math.round(optNum("rows", 2, 8, 5))
  readonly property int iconSizeMax: Math.round(optNum("iconSize", 32, 192, 96))
  readonly property bool showLabels: optBool("showLabels", true)
  readonly property string backdropMode: String(opt("backdrop") || "Wallpaper")   // Wallpaper | Glass | Desktop | Solid
  readonly property real blurAmount: optNum("blur", 0, 1, 1)
  readonly property real dim: optNum("dim", 0, 1, 0.45)
  readonly property bool glowEnabled: optBool("glow", true)
  readonly property bool shadowsEnabled: optBool("shadows", true)
  readonly property string animations: String(opt("animations") || "Full")     // Full | Subtle | None
  readonly property bool playful: animations === "Full"   // ripple, overshoot, zooms
  readonly property bool centered: String(opt("size") || "Fullscreen") === "Centered"
  readonly property bool vertical: String(opt("paging") || "Horizontal") === "Vertical"
  readonly property bool glass: backdropMode === "Glass"
  readonly property real cardWidth: optNum("width", 0.3, 1, 0.7)       // fraction of the screen
  readonly property real cardHeight: optNum("height", 0.3, 1, 0.75)
  readonly property int borderWidth: Math.round(optNum("borderWidth", 0, 12, 2))
  // Unset: the theme's corner radius, like other Omarchy surfaces.
  readonly property int cornerRadius: Math.round(optNum("radius", 0, 64, Style.cornerRadius))

  function ms(duration) { return root.animations === "None" ? 0 : duration }

  property bool opened: false
  property bool shown: false          // drives the fade/zoom-in once mapped
  property bool closing: false        // fading out before the host hides us
  property string filterText: ""
  property var items: []
  property int selectedIndex: 0
  property bool cursorActive: false   // keyboard cursor visible
  property int currentPage: 0
  property real swipeGain: 2.5        // touchpad deltas are small

  readonly property int pageCount: Model.pageCount(items.length, columns, rows)
  // A smaller grid set live can leave us past the last page.
  onPageCountChanged: if (currentPage >= pageCount) setPage(pageCount - 1, false)

  // Colours: [savanna] keys of shell.toml, falling back to the live Omarchy
  // palette, so a theme switch restyles Savanna on the spot. Values take a
  // hex colour or a role (accent, foreground, background, muted, urgent).
  readonly property color accent: Commons.Color.composed("savanna.accent", "savanna.accent-alpha", Commons.Color.accent, 1.0)
  readonly property color foreground: Commons.Color.composed("savanna.text", "savanna.text-alpha", Commons.Color.foreground, 1.0)
  readonly property color background: Commons.Color.composed("savanna.tint", "savanna.tint-alpha", Commons.Color.background, 1.0)
  readonly property color glowColor: Commons.Color.composed("savanna.glow", "savanna.glow-alpha", accent, 1.0)
  readonly property color selectedBackground: Commons.Color.composed("savanna.selected-background", "savanna.selected-background-alpha", accent, 0.24)
  readonly property color selectedBorder: Commons.Color.composed("savanna.selected-border", "savanna.selected-border-alpha", accent, 0.75)
  // Card border: the theme's Hyprland active border by default, so the card
  // looks like an Omarchy window.
  readonly property color borderColor: Commons.Color.composed("savanna.border", "savanna.border-alpha",
    Commons.Color.flatColor(Commons.Color.pick("hyprland.active-border", "accent"), accent), 1.0)
  // Backdrop tint strength: `dim` 0.45 reproduces the default look.
  // In Glass, Hyprland only blurs pixels above the layer rule's ignore_alpha
  // (0.3), so the tint never drops below it there.
  function tint(alpha) {
    var a = Math.min(1, alpha * root.dim / 0.45)
    return Util.alpha(root.background, root.glass ? Math.max(a, 0.34) : a)
  }
  readonly property string fontFamily: Style.font.menuFamily
  readonly property string wallpaper: Quickshell.env("HOME") + "/.local/state/omarchy/current/background"
  readonly property string themeName: themeNameFile.text().trim()

  // ---- lifecycle (called by omarchy-shell summon / hide) ----------------

  function open(payloadJson) {
    root.closing = false
    root.hoverArmed = false
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = false
    if (root.apps) root.apps.refreshIcons()
    root.rebuild()
    root.setPage(0, false)
    root.opened = true
    Qt.callLater(function() {
      keyCatcher.forceActiveFocus()
      root.reveal()
    })
    revealTimer.restart()
  }

  // The entrance waits for the blurred wallpaper (otherwise the first frames
  // show the bare tint, darker than the real thing), but never for long.
  function reveal() {
    if (root.shown || !root.opened || root.closing) return
    if (wallpaperImage.status === Image.Loading && revealTimer.running) return
    root.shown = true
  }

  Timer { id: revealTimer; interval: 300; onTriggered: root.reveal() }

  function close() {
    root.shown = false
    root.opened = false
  }

  // Our own exits (launch, Escape, click outside) fade and zoom out first;
  // the host hides the instance at once, so it has to be the last step.
  function dismiss() {
    if (root.closing) return
    root.closing = true
    root.shown = false
    closeTimer.start()
  }

  Timer {
    id: closeTimer
    interval: 190
    onTriggered: {
      root.close()
      if (root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
    }
  }

  // omarchy-shell shell call x99.savanna debugInfo ''
  function debugInfo(arg) {
    var rows = root.apps ? root.apps.sortedEntries("") : null
    return JSON.stringify({
      hasShell: !!root.shell, hasApps: !!root.apps,
      direct: root.shell ? String(root.shell.appLibrary) : "",
      manifestKinds: root.manifest ? root.manifest.kinds : null,
      shellKeys: root.shell ? Object.keys(root.shell).filter(function(k) { return k.indexOf("_") !== 0 }).slice(0, 30) : [],
      rows: rows ? rows.length : -1, items: root.items.length,
      page: root.currentPage, pages: root.pageCount, stripX: strip.x, stripY: strip.y,
      grid: (function() { var p = pagesView.mapToItem(null, 0, 0); return [p.x, p.y, pagesView.width, pagesView.height] })(),
      firstItem: root.items.length ? root.items[0].id : "",
      first: rows && rows.length ? Object.keys(rows[0]) : []
    })
  }

  // ---- data --------------------------------------------------------------

  function rebuild() {
    root.items = root.apps
      ? Model.itemsFromRows(root.apps.sortedEntries(root.filterText))
      : Model.itemsFromEntries(DesktopEntries.applications.values || [], root.filterText, root.hiddenIds)
    if (root.selectedIndex >= root.items.length) root.selectedIndex = Math.max(0, root.items.length - 1)
  }

  function setFilter(text) {
    root.filterText = text
    root.selectedIndex = 0
    root.cursorActive = text.length > 0
    root.rebuild()
    root.setPage(0, false)
  }

  // ---- navigation --------------------------------------------------------

  function setPage(page, animate) {
    pagesView.animated = animate !== false
    root.currentPage = Math.max(0, Math.min(root.pageCount - 1, page))
    pagesView.animated = true
  }

  // Touchpads scroll in phases (begin / update / end): the pages follow the
  // fingers. A mouse wheel has no phase: one page per notch.
  function scrollPages(wheel) {
    var px = wheel.pixelDelta, ang = wheel.angleDelta
    if (wheel.phase !== Qt.NoScrollPhase) {
      if (wheel.phase === Qt.ScrollEnd) {
        if (pagesView.tracking) root.settlePages(pagesView.velocity)
        return
      }
      if (wheel.phase === Qt.ScrollMomentum) return
      var d = root.swipeGain * (px.x !== 0 || px.y !== 0
        ? (Math.abs(px.x) >= Math.abs(px.y) ? px.x : px.y)
        : (Math.abs(ang.x) >= Math.abs(ang.y) ? ang.x : ang.y) / 8)
      if (d === 0) return
      var now = Date.now()
      var dt = now - pagesView.lastScroll
      var v = dt > 0 && dt < 100 ? d * 1000 / dt : 0
      pagesView.velocity = pagesView.tracking ? 0.6 * v + 0.4 * pagesView.velocity : v
      pagesView.lastScroll = now
      pagesView.tracking = true
      pagesView.offset = Model.clamp(pagesView.offset + d, -pagesView.span, pagesView.span)
      swipeEnd.restart()    // in case the end event never comes
      return
    }
    if (wheelCooldown.running) return
    pagesView.wheelAcc += ang.y !== 0 ? ang.y : ang.x
    if (Math.abs(pagesView.wheelAcc) >= 120) {
      root.turnPage(pagesView.wheelAcc < 0 ? 1 : -1)
      pagesView.wheelAcc = 0
      wheelCooldown.restart()
    }
  }

  // Hover selects, but only on real pointer motion: Qt also sends hover
  // moves when cells appear or slide under a still cursor (typing, paging),
  // and those must not steal the selection from the first result.
  property point hoverPos: Qt.point(-1, -1)
  property bool hoverArmed: false     // first event after open only records

  function hoverSelect(area, ev, index) {
    var p = area.mapToItem(null, ev.x, ev.y)
    if (!root.hoverArmed) {
      root.hoverArmed = true
      root.hoverPos = p
      return
    }
    if (p.x === root.hoverPos.x && p.y === root.hoverPos.y) return
    root.hoverPos = p
    root.cursorActive = true
    root.selectedIndex = index
  }

  // Click-drag on the grid moves the pages too. The cell and page
  // MouseAreas do it themselves: a DragHandler layered above them swallows
  // their clicks. Past a small threshold the press becomes a drag and no
  // longer counts as a click.
  property real dragStart: 0          // pointer position along the paging axis
  property real dragLast: 0
  property real dragLastTime: 0
  property bool dragging: false
  property bool dragged: false        // last press turned into a drag

  function dragPos(area, ev) {
    var p = area.mapToItem(pagesView, ev.x, ev.y)
    return root.vertical ? p.y : p.x
  }

  function dragPress(area, ev) {
    root.dragStart = root.dragLast = root.dragPos(area, ev)
    root.dragLastTime = Date.now()
    root.dragging = false
    root.dragged = false
  }

  function dragMove(area, ev) {
    if (!area.pressed) return     // hover moves on cells
    var x = root.dragPos(area, ev)
    if (!root.dragging) {
      if (Math.abs(x - root.dragStart) < Style.space(10)) return
      root.dragging = true
      root.dragged = true
      pagesView.tracking = true
    }
    var now = Date.now()
    var dt = now - root.dragLastTime
    if (dt > 0) pagesView.velocity = 0.6 * (x - root.dragLast) * 1000 / dt + 0.4 * pagesView.velocity
    root.dragLast = x
    root.dragLastTime = now
    pagesView.offset = x - root.dragStart
  }

  function dragRelease() {
    if (!root.dragging) return
    root.dragging = false
    root.settlePages(Date.now() - root.dragLastTime < 100 ? pagesView.velocity : 0)
  }

  // Ends a swipe or drag: flips one page when it went far or fast enough,
  // otherwise springs back.
  function settlePages(velocity) {
    swipeEnd.stop()
    var off = pagesView.offset
    var far = Math.abs(off) > Math.min(pagesView.span * 0.15, Style.space(160))
    var fast = Math.abs(velocity) > 800 && Math.abs(off) > Style.space(16) && (velocity < 0) === (off < 0)
    pagesView.tracking = false
    pagesView.offset = 0
    pagesView.velocity = 0
    if (far || fast) root.turnPage(off < 0 ? 1 : -1)
  }

  function moveCursor(direction) {
    if (root.items.length === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = root.currentPage * Model.perPage(root.columns, root.rows)
      return
    }
    root.selectedIndex = Model.move(root.selectedIndex, direction, root.items.length, root.columns, root.rows, root.vertical)
    root.setPage(Model.pageOf(root.selectedIndex, root.columns, root.rows), true)
  }

  function turnPage(delta) {
    var target = root.currentPage + delta
    if (target < 0 || target >= root.pageCount) return
    root.setPage(target, true)
    if (root.cursorActive)
      root.selectedIndex = Math.min(root.items.length - 1, target * Model.perPage(root.columns, root.rows))
  }

  function launch(index) {
    var item = root.items[index]
    if (!item || root.closing) return
    // Launch before dismissing: hiding destroys this instance right away.
    if (root.apps) root.apps.launch(item.id, item.name)
    else Quickshell.execDetached(["uwsm-app", "--", "gtk-launch", item.id + ".desktop"])
    root.dismiss()
  }

  function iconFor(icon) {
    if (root.apps) return root.apps.iconSource(icon)
    var value = String(icon || "")
    if (value.charAt(0) === "/") return "file://" + value
    return Quickshell.iconPath(value, "application-x-executable")
  }

  // Same hide list the Omarchy Apps menu honours.
  FileView {
    id: themeNameFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme.name"
    blockLoading: true
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
  }

  FileView {
    path: root.omarchyPath + "/default/omarchy/launcher.hides"
    watchChanges: true
    printErrors: false
    onLoaded: root.hiddenIds = Model.parseHides(text())
    onFileChanged: reload()
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { if (root.opened && !root.apps) root.rebuild() }
  }

  Connections {
    target: root.apps
    ignoreUnknownSignals: true
    function onAppsChanged() { if (root.opened) root.rebuild() }
  }

  // ---- window ------------------------------------------------------------

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    // Glass gets its own namespace so the Hyprland blur rule targets only it.
    WlrLayershell.namespace: root.glass ? "savanna-glass" : "savanna"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Centered mode: the desktop around the card is only dimmed.
    Rectangle {
      anchors.fill: parent
      visible: root.centered
      // Under the blur rule's ignore_alpha in Glass: dimmed, but kept sharp.
      color: Util.alpha(Commons.Color.background, root.glass ? 0.28 : 0.35)
      opacity: root.shown ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: root.ms(220); easing.type: Easing.OutCubic } }
    }

    // Click on empty space closes, like Launchpad.
    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (root.closing) return
        var k = event.key
        if (k === Qt.Key_Escape) {
          if (root.filterText) root.setFilter("")
          else root.dismiss()
        } else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
          root.launch(root.cursorActive ? root.selectedIndex : 0)
        } else if (Util.editsFilter(event, root.filterText)) {
          root.setFilter(Util.editedFilter(event, root.filterText))
        } else if (k === Qt.Key_Left) {
          root.moveCursor("left")
        } else if (k === Qt.Key_Right) {
          root.moveCursor("right")
        } else if (k === Qt.Key_Up) {
          root.moveCursor("up")
        } else if (k === Qt.Key_Down) {
          root.moveCursor("down")
        } else if (k === Qt.Key_PageDown) {
          root.turnPage(1)
        } else if (k === Qt.Key_PageUp) {
          root.turnPage(-1)
        } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
                   && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
          root.setFilter(root.filterText + event.text)
        } else {
          return
        }
        event.accepted = true
      }
    }

    // Drop shadow under the card (centered mode).
    Item {
      visible: root.centered
      x: frame.x; y: frame.y; width: frame.width; height: frame.height
      scale: frame.scale
      opacity: frame.opacity

      Rectangle {
        id: cardShape
        anchors.fill: parent
        radius: root.cornerRadius
        color: "black"
        visible: false
      }
      MultiEffect {
        anchors.fill: parent
        source: cardShape
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: "#000000"
        shadowOpacity: root.glass ? 0.25 : 0.55
        shadowBlur: 1.0
        shadowVerticalOffset: Style.space(10)
      }
    }

    // The launcher itself: the whole screen, or a card in the middle that
    // pops in. Everything inside (backdrop, grid) lays out against it.
    Item {
      id: frame
      readonly property real targetWidth: root.centered ? Math.round(panel.width * root.cardWidth) : panel.width
      readonly property real targetHeight: root.centered ? Math.round(panel.height * root.cardHeight) : panel.height
      width: targetWidth
      height: targetHeight
      x: Math.round((panel.width - width) / 2)
      y: Math.round((panel.height - height) / 2)
      scale: !root.centered || root.shown || !root.playful ? 1 : 0.94
      opacity: !root.centered || root.shown ? 1 : 0
      Behavior on scale { NumberAnimation { duration: root.ms(260); easing.type: Easing.OutCubic } }
      Behavior on opacity { NumberAnimation { duration: root.ms(200); easing.type: Easing.OutCubic } }

      // Rounded corners: mask the card with its own shape.
      layer.enabled: root.centered && root.cornerRadius > 0
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: frameMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
      }


      // Backdrop: the wallpaper, blurred and tinted with the theme, like
      // Launchpad over the desktop. It settles from a slight zoom on open.
      Item {
        anchors.fill: parent
        opacity: root.shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: root.ms(220); easing.type: Easing.OutCubic } }

        // Solid colour under the wallpaper; the whole backdrop in "Solid".
        // "Desktop" leaves only the tint over the live desktop (add a Hyprland
        // blur layer rule on the `savanna` namespace for frosted glass).
        Rectangle {
          anchors.fill: parent
          visible: root.backdropMode === "Wallpaper" || root.backdropMode === "Solid"
          color: Util.alpha(root.background, root.backdropMode === "Solid" ? 0.97 : 1)
        }

        Image {
          id: wallpaperImage
          x: -frame.x
          y: -frame.y
          width: panel.width
          height: panel.height
          // Cached across opens; the theme name in the URL busts the cache
          // when the theme (and so the wallpaper behind the link) changes.
          source: root.backdropMode === "Wallpaper"
            ? "file://" + root.wallpaper + "?theme=" + encodeURIComponent(root.themeName) : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
          // Blurred anyway: half resolution is plenty and much cheaper. Sized
          // from the screen, not the item: the item is 0 wide until mapped,
          // which would load the image twice.
          sourceSize.width: (panel.screen ? panel.screen.width : 1920) / 2
          sourceSize.height: (panel.screen ? panel.screen.height : 1200) / 2
          visible: false
          onStatusChanged: if (status !== Image.Loading) root.reveal()
        }

        MultiEffect {
          anchors.fill: wallpaperImage
          source: wallpaperImage
          visible: root.backdropMode === "Wallpaper" && wallpaperImage.status === Image.Ready
          autoPaddingEnabled: false
          blurEnabled: root.blurAmount > 0
          blur: root.blurAmount
          blurMax: 64
          blurMultiplier: 1.6
          saturation: 0.2
          scale: root.shown || !root.playful ? 1 : 1.08
          Behavior on scale { NumberAnimation { duration: root.ms(480); easing.type: Easing.OutCubic } }
        }

        // Theme tint, heavier at the top (search) and bottom (dots).
        Rectangle {
          anchors.fill: parent
          gradient: Gradient {
            GradientStop { position: 0.0; color: root.tint(0.72) }
            GradientStop { position: 0.35; color: root.tint(0.42) }
            GradientStop { position: 0.75; color: root.tint(0.48) }
            GradientStop { position: 1.0; color: root.tint(0.82) }
          }
        }

        // Glass sheen: a faint light catching the top of the pane.
        Rectangle {
          anchors.fill: parent
          visible: root.glass
          gradient: Gradient {
            GradientStop { position: 0.0; color: Util.alpha(root.foreground, 0.10) }
            GradientStop { position: 0.3; color: Util.alpha(root.foreground, 0.03) }
            GradientStop { position: 0.6; color: "transparent" }
          }
        }

        // Side vignette.
        Rectangle {
          anchors.fill: parent
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: root.tint(0.45) }
            GradientStop { position: 0.18; color: "transparent" }
            GradientStop { position: 0.82; color: "transparent" }
            GradientStop { position: 1.0; color: root.tint(0.45) }
          }
        }

        // Soft accent glow above the search field: a small blurred ellipse,
        // scaled up so its edges melt away.
        Item {
          width: Style.space(260)
          height: Style.space(70)
          anchors.horizontalCenter: parent.horizontalCenter
          y: -height * 0.2
          visible: root.glowEnabled
          scale: 5.5
          opacity: 0.45

          Rectangle {
            id: glowShape
            anchors.fill: parent
            radius: height / 2
            color: root.glowColor
            visible: false
          }

          MultiEffect {
            anchors.fill: parent
            source: glowShape
            autoPaddingEnabled: true
            blurEnabled: true
            blur: 1.0
            blurMax: 48
          }
        }
      }

      Item {
        id: content
        anchors.fill: parent
        anchors.margins: Style.space(root.centered ? 28 : 48)
        opacity: root.shown ? 1 : 0
        scale: root.shown || !root.playful ? 1 : 1.06
        Behavior on opacity { NumberAnimation { duration: root.ms(180); easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: root.ms(220); easing.type: Easing.OutCubic } }

        // Search field: a frosted pill that widens and lights up in the
        // accent colour as soon as you type.
        Item {
          id: search
          readonly property bool active: root.filterText.length > 0
          anchors.top: parent.top
          anchors.horizontalCenter: parent.horizontalCenter
          width: Style.space(active ? 380 : 300)
          height: Style.font.heading + Style.space(22)
          Behavior on width { NumberAnimation { duration: root.ms(260); easing.type: Easing.OutCubic } }

          // Accent halo behind the pill while typing.
          Rectangle {
            id: haloShape
            anchors.fill: parent
            radius: height / 2
            color: root.accent
            visible: false
          }
          MultiEffect {
            anchors.fill: parent
            source: haloShape
            autoPaddingEnabled: true
            blurEnabled: true
            blur: 1.0
            blurMax: 32
            opacity: search.active ? 0.35 : 0
            Behavior on opacity { NumberAnimation { duration: root.ms(200) } }
          }

          Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: search.active ? Util.alpha(root.background, 0.72) : Util.alpha(root.foreground, 0.12)
            border.width: 1
            border.color: search.active ? Util.alpha(root.accent, 0.9) : Util.alpha(root.foreground, 0.24)
            Behavior on color { ColorAnimation { duration: root.ms(200) } }
            Behavior on border.color { ColorAnimation { duration: root.ms(200) } }
          }

          MouseArea { anchors.fill: parent; onClicked: {} }

          // Centred while empty, slides to the left once there is a query.
          Row {
            id: searchRow
            anchors.verticalCenter: parent.verticalCenter
            x: search.active ? Style.space(18) : (search.width - width) / 2
            spacing: Style.space(10)
            Behavior on x { NumberAnimation { duration: root.ms(260); easing.type: Easing.OutCubic } }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "󰍉"
              color: search.active ? root.accent : root.foreground
              opacity: search.active ? 1 : 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              Behavior on color { ColorAnimation { duration: root.ms(200) } }
            }

            Text {
              id: queryText
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, search.width - Style.space(150))
              textFormat: Text.PlainText
              text: root.filterText || "Search"
              color: root.foreground
              opacity: search.active ? 1 : 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              elide: Text.ElideLeft
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              visible: search.active
              width: 2
              height: queryText.font.pixelSize * 1.15
              radius: 1
              color: root.accent
              SequentialAnimation on opacity {
                running: search.active && root.animations !== "None"
                loops: Animation.Infinite
                NumberAnimation { to: 1; duration: 0 }
                PauseAnimation { duration: 520 }
                NumberAnimation { to: 0; duration: 180 }
                PauseAnimation { duration: 340 }
                NumberAnimation { to: 1; duration: 180 }
              }
            }
          }

          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(18)
            anchors.verticalCenter: parent.verticalCenter
            opacity: search.active ? 0.6 : 0
            Behavior on opacity { NumberAnimation { duration: root.ms(200) } }
            textFormat: Text.PlainText
            text: root.items.length + (root.items.length === 1 ? " app" : " apps")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        // Pages sit side by side on a strip that slides to the current page.
        // Swipes and drags move it live, then it settles on a page.
        Item {
          id: pagesView
          anchors.top: search.bottom
          anchors.topMargin: Style.space(32)
          // Horizontal paging: dots below. Vertical: dots down the right side.
          anchors.bottom: root.vertical ? parent.bottom : dots.top
          anchors.bottomMargin: root.vertical ? 0 : Style.space(16)
          anchors.left: parent.left
          anchors.right: root.vertical ? dots.left : parent.right
          anchors.rightMargin: root.vertical ? Style.space(16) : 0
          clip: true

          // Page length along the paging axis.
          readonly property real span: root.vertical ? height : width

          property real offset: 0           // live swipe/drag offset, px
          property real velocity: 0         // px/s, sign follows offset
          property real lastScroll: 0
          property real wheelAcc: 0
          property bool tracking: false
          property bool animated: true
          readonly property bool atEdge: (offset > 0 && root.currentPage === 0)
            || (offset < 0 && root.currentPage === root.pageCount - 1)

          // Wheel / touchpad scrolling. It sits below the pages: cells and page
          // backgrounds ignore wheel events, so those fall through to here,
          // while clicks never do. A MouseArea rather than a WheelHandler: it
          // accepts the wheel event, so the rest of a touchpad scroll keeps
          // coming here.
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            onWheel: function(wheel) {
              root.scrollPages(wheel)
              wheel.accepted = true
            }
          }

          Item {
            id: strip
            readonly property real shift: -root.currentPage * pagesView.span
              + (pagesView.atEdge ? pagesView.offset * 0.25 : pagesView.offset)
            width: root.vertical ? pagesView.width : pagesView.width * root.pageCount
            height: root.vertical ? pagesView.height * root.pageCount : pagesView.height
            x: root.vertical ? 0 : shift
            y: root.vertical ? shift : 0
            Behavior on x {
              enabled: pagesView.animated && !pagesView.tracking
              NumberAnimation { duration: root.ms(280); easing.type: Easing.OutCubic }
            }
            Behavior on y {
              enabled: pagesView.animated && !pagesView.tracking
              NumberAnimation { duration: root.ms(280); easing.type: Easing.OutCubic }
            }

            Repeater {
              model: root.pageCount

              delegate: Item {
                id: page
                required property int index
                x: root.vertical ? 0 : index * pagesView.width
                y: root.vertical ? index * pagesView.height : 0
                width: pagesView.width
                height: pagesView.height

                readonly property var pageItems: Model.slice(root.items, index, root.columns, root.rows)
                readonly property real cellW: width / root.columns
                readonly property real cellH: height / root.rows
                // The icon gets what the cell leaves once the label and its
                // spacing are taken out, so a squat card never overlaps them.
                readonly property real labelSpace: root.showLabels ? Style.font.body * 1.4 + Style.space(10) : 0
                readonly property real iconSize: Math.max(Style.space(16),
                  Math.min(cellW * 0.55, (cellH - labelSpace) * 0.72, Style.space(root.iconSizeMax)))

                MouseArea {
                  id: pageArea
                  anchors.fill: parent
                  onPressed: function(ev) { root.dragPress(pageArea, ev) }
                  onPositionChanged: function(ev) { root.dragMove(pageArea, ev) }
                  onReleased: root.dragRelease()
                  onCanceled: root.dragRelease()
                  // Empty space closes in fullscreen, like Launchpad; a card only
                  // closes from a click outside it.
                  onClicked: if (!root.dragged && !root.centered) root.dismiss()
                }

                // One soft drop shadow for the whole page: icons float above the
                // backdrop and labels stay readable on bright wallpapers.
                Item {
                  anchors.fill: parent
                  layer.enabled: root.shadowsEnabled
                  layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: "#000000"
                    shadowOpacity: 0.5
                    shadowBlur: 0.6
                    shadowVerticalOffset: Style.space(4)
                  }

                  Repeater {
                    model: page.pageItems

                    delegate: Item {
                      id: cell
                      required property int index
                      required property var modelData
                      readonly property int globalIndex: page.index * Model.perPage(root.columns, root.rows) + index
                      readonly property bool selected: root.cursorActive && globalIndex === root.selectedIndex

                      x: (index % root.columns) * page.cellW
                      y: Math.floor(index / root.columns) * page.cellH
                      width: page.cellW
                      height: page.cellH

                      // On open, cells pop in as a ripple from the middle of the page.
                      readonly property real rippleDelay: (root.playful ? 40 : 0) * Math.sqrt(
                        Math.pow(index % root.columns - (root.columns - 1) / 2, 2)
                        + Math.pow(Math.floor(index / root.columns) - (root.rows - 1) / 2, 2))
                      // A cell waits for its icon, so a label never shows up alone.
                    property real appear: root.shown && iconImage.status !== Image.Loading ? 1 : 0
                      Behavior on appear {
                        SequentialAnimation {
                          PauseAnimation { duration: root.ms(60 + cell.rippleDelay) }
                          NumberAnimation { duration: root.ms(340); easing.type: root.playful ? Easing.OutBack : Easing.OutCubic; easing.overshoot: 1.4 }
                        }
                      }

                      Item {
                        anchors.fill: parent
                        opacity: Math.min(1, cell.appear)
                        scale: 0.75 + 0.25 * cell.appear

                        // Selection tile, tinted with the accent.
                        Rectangle {
                          anchors.centerIn: parent
                          width: Math.min(page.cellW - Style.space(8), page.iconSize * 1.75)
                          height: page.iconSize + (root.showLabels ? label.implicitHeight : 0) + Style.space(30)
                          radius: Style.space(20)
                          color: root.selectedBackground
                          border.width: 1
                          border.color: root.selectedBorder
                          opacity: cell.selected ? 1 : 0
                          scale: cell.selected ? 1 : 0.9
                          Behavior on opacity { NumberAnimation { duration: root.ms(160) } }
                          Behavior on scale { NumberAnimation { duration: root.ms(220); easing.type: root.playful ? Easing.OutBack : Easing.OutCubic } }
                        }

                        Column {
                          anchors.centerIn: parent
                          spacing: Style.space(10)

                          Image {
                            id: iconImage
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: page.iconSize
                            height: page.iconSize
                            sourceSize.width: page.iconSize * 2
                            sourceSize.height: page.iconSize * 2
                            source: root.iconFor(cell.modelData.icon)
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            smooth: true
                            mipmap: true
                            scale: mouse.pressed ? 0.88 : (cell.selected ? 1.1 : 1)
                            Behavior on scale { NumberAnimation { duration: root.ms(240); easing.type: root.playful ? Easing.OutBack : Easing.OutCubic; easing.overshoot: 2 } }
                          }

                          Text {
                            id: label
                            visible: root.showLabels
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: page.cellW - Style.space(16)
                            textFormat: Text.PlainText
                            text: cell.modelData.name
                            color: root.foreground
                            opacity: cell.selected ? 1 : 0.86
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            font.weight: cell.selected ? Font.DemiBold : Font.Medium
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                          }
                        }
                      }

                      MouseArea {
                        id: mouse
                        anchors.centerIn: parent
                        width: Math.min(page.cellW, page.iconSize * 1.7)
                        height: page.iconSize + (root.showLabels ? label.implicitHeight : 0) + Style.space(24)
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onPressed: function(ev) { root.dragPress(mouse, ev) }
                        onPositionChanged: function(ev) {
                          if (!mouse.pressed) root.hoverSelect(mouse, ev, cell.globalIndex)
                          root.dragMove(mouse, ev)
                        }
                        onReleased: root.dragRelease()
                        onCanceled: root.dragRelease()
                        onClicked: if (!root.dragged) root.launch(cell.globalIndex)
                      }
                    }
                  }
                }
              }
            }
          }

          Timer { id: swipeEnd; interval: 300; onTriggered: root.settlePages(pagesView.velocity) }
        }

        Text {
          anchors.centerIn: pagesView
          visible: root.items.length === 0
          textFormat: Text.PlainText
          text: root.filterText ? "No results for “" + root.filterText + "”" : "No applications"
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.weight: Font.Light
        }

        // Page dots
        Grid {
          id: dots
          // Placed by coordinates, not conditional anchors: anchors switched
          // to `undefined` live are not always released, which once left the
          // dots at the top and squashed the grid to nothing. Vertical: down
          // the right edge, centred on the grid area below the search field.
          readonly property real gridTop: search.height + Style.space(32)
          x: root.vertical ? parent.width - width : Math.round((parent.width - width) / 2)
          y: root.vertical ? Math.round(gridTop + (parent.height - gridTop - height) / 2) : parent.height - height
          columns: root.vertical ? 1 : Math.max(1, root.pageCount)
          spacing: Style.space(10)
          horizontalItemAlignment: Grid.AlignHCenter
          verticalItemAlignment: Grid.AlignVCenter
          visible: root.pageCount > 1

          Repeater {
            model: root.pageCount
            // The current page's dot stretches into an accent pill.
            delegate: Rectangle {
              required property int index
              readonly property bool current: index === root.currentPage
              width: current && !root.vertical ? Style.space(24) : Style.space(8)
              height: current && root.vertical ? Style.space(24) : Style.space(8)
              radius: Math.min(width, height) / 2
              color: current ? root.accent : Util.alpha(root.foreground, 0.35)
              Behavior on width { NumberAnimation { duration: root.ms(260); easing.type: Easing.OutCubic } }
              Behavior on height { NumberAnimation { duration: root.ms(260); easing.type: Easing.OutCubic } }
              Behavior on color { ColorAnimation { duration: root.ms(260) } }
              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setPage(index, true)
              }
            }
          }
        }
      }
    }

    Item {
      id: frameMask
      width: frame.width
      height: frame.height
      layer.enabled: true
      visible: false
      Rectangle { anchors.fill: parent; radius: root.cornerRadius; color: "black" }
    }

    // Border, drawn over the card like a Hyprland window border.
    Rectangle {
      visible: root.centered && root.borderWidth > 0
      x: frame.x; y: frame.y; width: frame.width; height: frame.height
      scale: frame.scale
      opacity: frame.opacity
      radius: root.cornerRadius
      color: "transparent"
      border.width: root.borderWidth
      border.color: root.borderColor
    }


    Timer { id: wheelCooldown; interval: 350 }
  }
}
