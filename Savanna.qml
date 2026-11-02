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
  // The entrance is over: cells created from now on (search, removal) show
  // at once instead of replaying the ripple.
  property bool revealed: false
  onShownChanged: if (shown) revealedTimer.restart(); else revealed = false
  Timer { id: revealedTimer; interval: 900; onTriggered: root.revealed = true }
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
    root.editMode = false
    root.confirmTarget = null
    root.removedIds = ({})
    root.revealed = false
    root.scanProtected()
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
      editMode: root.editMode, protectedCount: Object.keys(root.protectedIds).length,
      first: rows && rows.length ? Object.keys(rows[0]) : []
    })
  }

  // ---- data --------------------------------------------------------------

  function rebuild() {
    var list = root.apps
      ? Model.itemsFromRows(root.apps.sortedEntries(root.filterText))
      : Model.itemsFromEntries(DesktopEntries.applications.values || [], root.filterText, root.hiddenIds)
    root.items = list.filter(function(item) { return root.removedIds[item.id] !== true })
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

  // ---- uninstalling ------------------------------------------------------
  //
  // Launchpad-style: a long press on an icon enters edit mode (icons wiggle,
  // a cross on the removable ones), or Delete on the selected app. The
  // confirmation first asks bin/savanna-uninstall what removing it involves
  // (a pacman dry run for packages), then runs it while Savanna stays open:
  // the icon vanishes and the others slide into place. Packages ask for the
  // password through the shell's polkit agent. Apps Omarchy relies on are
  // protected: see bin/savanna-protected.

  property bool editMode: false
  property var protectedIds: ({})
  property var confirmTarget: null
  property int confirmChoice: 0       // 0 = Cancel (or OK), 1 = Uninstall
  property string confirmPhase: "ask" // ask | working | failed
  property var confirmPlan: ({})      // from `savanna-uninstall plan`; {} while it runs
  property string confirmError: ""
  readonly property bool confirmProtected: confirmTarget !== null && isProtected(confirmTarget.id)
  readonly property bool planReady: confirmPlan.kind !== undefined
  // Nothing to confirm: protected, unknown to the uninstaller, or pacman refuses.
  readonly property bool confirmBlocked: confirmProtected
    || (planReady && (confirmPlan.kind === "unknown" || confirmPlan.blocked !== undefined))

  function isProtected(id) { return root.protectedIds[String(id)] === true }

  function scriptPath(name) {
    return decodeURIComponent(String(Qt.resolvedUrl("bin/" + name)).replace(/^file:\/\//, ""))
  }

  function askRemove(index) {
    var item = root.items[index]
    if (!item) return
    root.confirmChoice = 0
    root.confirmPhase = "ask"
    root.confirmPlan = ({})
    root.confirmError = ""
    root.confirmTarget = item
    if (root.isProtected(item.id)) return
    planProc.output = ""
    planProc.command = [root.scriptPath("savanna-uninstall"), "plan", item.id]
    planProc.running = true
  }

  function cancelRemove() {
    if (root.confirmPhase === "working") return
    root.confirmTarget = null
  }

  function applyConfirm() {
    if (root.confirmPhase === "working") return
    var item = root.confirmTarget
    if (!item || root.confirmBlocked || root.confirmPhase === "failed" || root.confirmChoice !== 1) {
      root.confirmTarget = null
      return
    }
    if (!root.planReady) return        // still checking; Enter again in a moment
    root.confirmPhase = "working"
    removeProc.lastError = ""
    removeProc.itemId = item.id
    removeProc.command = [root.scriptPath("savanna-uninstall"), "run", item.id, item.name]
    removeProc.running = true
  }

  function scanProtected() {
    if (protectedScan.running) return
    protectedScan.output = ""
    protectedScan.running = true
  }

  Process {
    id: protectedScan
    property string output: ""
    command: [root.scriptPath("savanna-protected")]
    stdout: SplitParser { onRead: function(line) { protectedScan.output += line + "\n" } }
    onExited: root.protectedIds = Model.parseHides(protectedScan.output)
  }

  Process {
    id: planProc
    property string output: ""
    stdout: SplitParser { onRead: function(line) { planProc.output += line + "\n" } }
    onExited: {
      var plan = {}
      planProc.output.split("\n").forEach(function(line) {
        var i = line.indexOf("=")
        if (i > 0) plan[line.slice(0, i)] = line.slice(i + 1)
      })
      if (!plan.kind) plan.kind = "unknown"
      root.confirmPlan = plan
    }
  }

  Process {
    id: removeProc
    property string itemId: ""
    property string lastError: ""
    stderr: SplitParser { onRead: function(line) { if (line.trim()) removeProc.lastError = line.trim() } }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.vanish(removeProc.itemId)   // first, so rebuilds stay on hold
        root.confirmTarget = null
        root.confirmPhase = "ask"
      } else {
        // pkexec: 126 = prompt dismissed, 127 = not authorised.
        root.confirmError = exitCode === 126 || exitCode === 127
          ? "The password prompt was cancelled. Nothing was removed."
          : (removeProc.lastError || "The uninstaller stopped with code " + exitCode + ".")
        root.confirmPhase = "failed"
        root.confirmChoice = 0
      }
      keyCatcher.forceActiveFocus()
    }
  }

  // The app list changes on disk as soon as an uninstall removes the entry,
  // before the uninstaller even exits: hold those rebuilds until the removal
  // animation has run, or the gap would close with a jump.
  readonly property bool holdRebuild: confirmPhase === "working" || vanishingId !== ""
  property bool rebuildPending: false
  onHoldRebuildChanged: if (!holdRebuild && rebuildPending) refresh()

  function refresh() {
    if (root.holdRebuild) {
      root.rebuildPending = true
      return
    }
    root.rebuildPending = false
    root.rebuild()
  }

  // Removal animation: the icon shrinks away, then the grid is rebuilt
  // without it and every cell that moved slides from its old spot (FLIP).
  property string vanishingId: ""
  property var removedIds: ({})       // gone until the desktop entries catch up
  property var flipFrom: ({})         // id -> index before the rebuild

  function vanish(id) {
    root.vanishingId = String(id)
    vanishTimer.restart()
  }

  Timer {
    id: vanishTimer
    interval: root.ms(230)
    onTriggered: {
      var from = {}
      for (var i = 0; i < root.items.length; i++) from[root.items[i].id] = i
      var removed = {}
      for (var k in root.removedIds) removed[k] = true
      removed[root.vanishingId] = true
      root.flipFrom = from
      root.removedIds = removed
      root.rebuild()
      root.rebuildPending = false        // this rebuild already has the new list
      root.flipFrom = ({})
      root.vanishingId = ""
    }
  }

  // Top-left corner of a grid index, in strip coordinates.
  function cellPos(index) {
    var n = Model.perPage(root.columns, root.rows)
    var page = Math.floor(index / n)
    var local = index % n
    var cw = pagesView.width / root.columns
    var ch = pagesView.height / root.rows
    return {
      x: (root.vertical ? 0 : page * pagesView.width) + (local % root.columns) * cw,
      y: (root.vertical ? page * pagesView.height : 0) + Math.floor(local / root.columns) * ch
    }
  }

  Component.onCompleted: scanProtected()

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
    function onValuesChanged() { if (root.opened && !root.apps) root.refresh() }
  }

  Connections {
    target: root.apps
    ignoreUnknownSignals: true
    function onAppsChanged() { if (root.opened) root.refresh() }
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
    // Let go of the keyboard while uninstalling: the polkit prompt needs it.
    WlrLayershell.keyboardFocus: root.opened && root.confirmPhase !== "working"
      ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
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

    // Click on empty space closes, like Launchpad (or leaves edit mode).
    MouseArea {
      anchors.fill: parent
      onClicked: root.editMode ? (root.editMode = false) : root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (root.closing) return
        var k = event.key
        if (root.confirmTarget) {
          // The confirmation owns the keyboard while it is up.
          if (k === Qt.Key_Escape) root.cancelRemove()
          else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) root.applyConfirm()
          else if (root.confirmPhase === "ask" && !root.confirmBlocked
                   && (k === Qt.Key_Left || k === Qt.Key_Right || k === Qt.Key_Tab || k === Qt.Key_Backtab))
            root.confirmChoice = 1 - root.confirmChoice
          event.accepted = true
          return
        }
        if (k === Qt.Key_Escape && root.editMode) {
          root.editMode = false
        } else if (k === Qt.Key_Delete && root.cursorActive && root.items.length > 0) {
          root.askRemove(root.selectedIndex)
        } else if (k === Qt.Key_Escape) {
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
                  onClicked: {
                    if (root.dragged) return
                    if (root.editMode) root.editMode = false
                    else if (!root.centered) root.dismiss()
                  }
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
                        enabled: !root.revealed
                        SequentialAnimation {
                          PauseAnimation { duration: root.ms(60 + cell.rippleDelay) }
                          NumberAnimation { duration: root.ms(340); easing.type: root.playful ? Easing.OutBack : Easing.OutCubic; easing.overshoot: 1.4 }
                        }
                      }

                      // Uninstalled: shrink away before the grid closes the gap.
                      property real gone: root.vanishingId === modelData.id ? 1 : 0
                      Behavior on gone { NumberAnimation { duration: root.ms(220); easing.type: Easing.InCubic } }

                      // After a removal, start where this app used to be and slide home.
                      property real flipX: 0
                      property real flipY: 0
                      ParallelAnimation {
                        id: flipAnim
                        NumberAnimation { target: cell; property: "flipX"; to: 0; duration: root.ms(340); easing.type: Easing.OutCubic }
                        NumberAnimation { target: cell; property: "flipY"; to: 0; duration: root.ms(340); easing.type: Easing.OutCubic }
                      }
                      Component.onCompleted: {
                        var old = root.flipFrom[modelData.id]
                        if (old === undefined || old === globalIndex) return
                        var a = root.cellPos(old)
                        var b = root.cellPos(globalIndex)
                        flipX = a.x - b.x
                        flipY = a.y - b.y
                        flipAnim.start()
                      }

                      Item {
                        anchors.fill: parent
                        opacity: Math.min(1, cell.appear) * (1 - cell.gone)
                        scale: (0.75 + 0.25 * cell.appear) * (1 - 0.8 * cell.gone)
                        transform: Translate { x: cell.flipX; y: cell.flipY }

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
                            // Once open, icons come from the cache: load them in place
                            // so re-created cells never flash empty.
                            asynchronous: !root.revealed
                            smooth: true
                            mipmap: true
                            scale: mouse.pressed ? 0.88 : (cell.selected ? 1.1 : 1)
                            Behavior on scale { NumberAnimation { duration: root.ms(240); easing.type: root.playful ? Easing.OutBack : Easing.OutCubic; easing.overshoot: 2 } }

                            // Edit mode: icons wiggle, each slightly out of step.
                            property real wiggle: 0
                            rotation: root.editMode ? wiggle : 0
                            SequentialAnimation on wiggle {
                              running: root.editMode && root.animations !== "None"
                              loops: Animation.Infinite
                              PauseAnimation { duration: (cell.globalIndex * 47) % 140 }
                              NumberAnimation { to: 2.4; duration: 110; easing.type: Easing.InOutSine }
                              NumberAnimation { to: -2.4; duration: 220; easing.type: Easing.InOutSine }
                              NumberAnimation { to: 0; duration: 110; easing.type: Easing.InOutSine }
                            }

                            // Cross on removable apps, top-left like Launchpad.
                            Rectangle {
                              id: removeBadge
                              readonly property bool shown: root.editMode && !root.isProtected(cell.modelData.id)
                              width: Style.space(24)
                              height: width
                              radius: width / 2
                              x: -width * 0.3
                              y: -height * 0.3
                              visible: opacity > 0
                              opacity: shown ? 1 : 0
                              scale: shown ? 1 : 0.4
                              color: Util.alpha(root.background, 0.92)
                              border.width: 1
                              border.color: Util.alpha(root.foreground, 0.35)
                              Behavior on opacity { NumberAnimation { duration: root.ms(140) } }
                              Behavior on scale { NumberAnimation { duration: root.ms(200); easing.type: root.playful ? Easing.OutBack : Easing.OutCubic } }

                              Text {
                                anchors.centerIn: parent
                                text: "✕"
                                color: root.foreground
                                font.pixelSize: parent.width * 0.5
                                font.bold: true
                              }
                            }
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
                        pressAndHoldInterval: 450
                        onPressAndHold: if (!root.dragging) root.editMode = true
                        onClicked: function(ev) {
                          if (root.dragged) return
                          if (!root.editMode) {
                            root.launch(cell.globalIndex)
                            return
                          }
                          // In edit mode only the cross acts (with some slack).
                          var p = mouse.mapToItem(removeBadge, ev.x, ev.y)
                          var slack = Style.space(8)
                          if (removeBadge.shown && p.x >= -slack && p.y >= -slack
                              && p.x <= removeBadge.width + slack && p.y <= removeBadge.height + slack)
                            root.askRemove(cell.globalIndex)
                        }
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


    // Uninstall confirmation, over everything. Cancel is preselected; for an
    // app Omarchy relies on it only explains why it stays.
    Item {
      anchors.fill: parent
      visible: root.confirmTarget !== null
      z: 10

      Rectangle { anchors.fill: parent; color: Util.alpha(Commons.Color.background, 0.4) }
      MouseArea { anchors.fill: parent; onClicked: root.cancelRemove() }   // ignored while working

      Rectangle {
        anchors.centerIn: parent
        width: Style.space(400)
        height: confirmColumn.implicitHeight + Style.space(48)
        radius: Math.max(root.cornerRadius, Style.space(14))
        color: Util.alpha(root.background, 0.97)
        border.width: 1
        border.color: root.confirmBlocked ? Util.alpha(root.foreground, 0.2) : Util.alpha(Commons.Color.urgent, 0.6)

        MouseArea { anchors.fill: parent }   // clicks on the card stay on it

        Column {
          id: confirmColumn
          anchors.centerIn: parent
          width: parent.width - Style.space(48)
          spacing: Style.space(14)

          Image {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Style.space(64)
            height: width
            sourceSize.width: width * 2
            sourceSize.height: height * 2
            source: root.confirmTarget ? root.iconFor(root.confirmTarget.icon) : ""
            fillMode: Image.PreserveAspectFit
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: {
              if (!root.confirmTarget) return ""
              var name = "“" + root.confirmTarget.name + "”"
              if (root.confirmProtected) return name + " is part of Omarchy"
              if (root.confirmBlocked) return "Can't uninstall " + name
              if (root.confirmPhase === "working") return "Uninstalling " + name + "…"
              if (root.confirmPhase === "failed") return "Couldn't uninstall " + name
              return "Uninstall " + name + "?"
            }
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.weight: Font.DemiBold
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: {
              var plan = root.confirmPlan
              if (root.confirmProtected) return "Savanna leaves the apps Omarchy relies on alone."
              if (root.confirmPhase === "failed") return root.confirmError
              if (!root.planReady) return "Checking what goes with it…"
              if (plan.kind === "unknown") return "Savanna doesn't know how this app was installed."
              if (plan.blocked !== undefined)
                return plan.blocked === "pacman refuses" ? "pacman refuses to remove it." : "It is needed by " + plan.blocked + "."
              if (root.confirmPhase === "working")
                return plan.kind === "package" ? "Enter your password in the prompt." : "One moment…"
              if (plan.kind === "webapp") return "Removes this web app."
              if (plan.kind === "tui") return "Removes this terminal app."
              if (plan.kind === "user") return "Removes this launcher entry."
              if (plan.kind === "flatpak") return "Removes the " + plan.package + " Flatpak."
              // A package: name it, and what pacman would take along.
              var also = plan.also ? plan.also.split(" ") : []
              var text = "Removes the " + plan.package + " package"
              if (also.length > 0)
                text += " and " + (also.length === 1 ? "1 package" : also.length + " packages") + " only it needed ("
                  + also.slice(0, 4).join(", ") + (also.length > 4 ? ", …" : "") + ")"
              return text + ". You'll be asked for your password."
            }
            color: root.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // Working: three dots pulsing in turn.
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.confirmPhase === "working"
            spacing: Style.space(8)
            Repeater {
              model: 3
              delegate: Rectangle {
                required property int index
                width: Style.space(8)
                height: width
                radius: width / 2
                color: root.accent
                opacity: 0.25
                SequentialAnimation on opacity {
                  running: root.confirmPhase === "working"
                  loops: Animation.Infinite
                  PauseAnimation { duration: index * 160 }
                  NumberAnimation { to: 1; duration: 240 }
                  NumberAnimation { to: 0.25; duration: 240 }
                  PauseAnimation { duration: (2 - index) * 160 }
                }
              }
            }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(12)

            Repeater {
              model: root.confirmPhase === "working" ? []
                : root.confirmBlocked || root.confirmPhase === "failed" ? ["OK"] : ["Cancel", "Uninstall"]

              delegate: Rectangle {
                required property int index
                required property string modelData
                readonly property bool chosen: index === root.confirmChoice
                readonly property bool danger: modelData === "Uninstall"
                width: Style.space(140)
                height: Style.font.body + Style.space(22)
                radius: height / 2
                color: chosen ? (danger ? Commons.Color.urgent : Util.alpha(root.accent, 0.25)) : Util.alpha(root.foreground, 0.08)
                border.width: 1
                border.color: chosen ? (danger ? Commons.Color.urgent : root.accent) : Util.alpha(root.foreground, 0.2)
                Behavior on color { ColorAnimation { duration: root.ms(120) } }

                Text {
                  anchors.centerIn: parent
                  text: parent.modelData
                  color: parent.chosen && parent.danger ? root.background : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.weight: Font.DemiBold
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.confirmChoice = parent.index
                  onClicked: {
                    root.confirmChoice = parent.index
                    root.applyConfirm()
                  }
                }
              }
            }
          }
        }
      }
    }

    Timer { id: wheelCooldown; interval: 350 }
  }
}
