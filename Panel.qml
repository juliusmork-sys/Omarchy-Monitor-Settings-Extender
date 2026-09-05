import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.monitor"
  ipcTarget: "omarchy.monitor"
  manageIpc: false

  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the brightness + state methods below.
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  property string internalMonitor: ""
  property string externalMonitor: ""
  property string focusedMonitor: ""
  property bool internalEnabled: false
  property bool mirrorEnabled: false
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0
  // Connector name (eDP-1, DP-7, ...) -> friendly name (make + model, or
  // "Built-in Display"), fetched separately from omarchy-monitor-state since
  // that shared script doesn't carry EDID make/model/description.
  property var monitorLabels: ({})
  // Full per-monitor info (position, mode, transform, refresh rate, ...)
  // from the same fetch, ordered as hyprctl returns it and keyed by name.
  // Backs refresh rate, mirror, arrangement and cursor-size below.
  property var monitorInfoList: []
  property var monitorInfoByName: ({})
  property int cursorSize: 24
  // Set by the dropdown itself (onPopupOpenChanged) so keyCatcher can
  // suspend without holding a direct id reference to it.
  property bool refreshRateDropdownOpen: false
  // One rotation dropdown per Displays row (a Repeater), so this counts
  // open popups rather than tracking a single id/bool.
  property int openRotationDropdownCount: 0
  // True while a box is being dragged in the Arrangement diagram. Pauses
  // the periodic refresh below it — a mid-drag refresh would rebuild
  // ArrangementDiagram's `boxes` model, recreating the Repeater's
  // delegates (and this one's in-progress drag state) out from under it.
  property bool arrangementDragActive: false
  // Set by runAction() whenever a monitor-changing command runs while this
  // panel is open; consumed by onOpenedChanged if that action forces the
  // popup closed. See runAction for why this is the *second* of two
  // reopen mechanisms (this one in-memory, the other file-based).
  property bool pendingReopen: false

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Cursor model shared by keyboard and mouse. Sections:
  //   "brightness" - single slider row, selectedIndex = -1 sentinel
  //                  (mirrors Audio's slider rows). Only present if a
  //                  controllable backlight was detected.
  //   "scale"      - 6 Button scale presets; treated as a single
  //                  horizontal row from j/k's perspective. h/l moves
  //                  between presets, identical to bluetooth's header.
  //   "monitors"   - vertical display row list for enabling/disabling displays;
  //                  j/k walks each row.
  // Mouse hover on a target updates root state via the components' `hovered`
  // signal so keyboard cursor and pointer share one highlight.
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var scaleValues: {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.availableScales(scalePresets, display.width, display.height)
    }
    return scalePresets
  }
  property string focusSection: "scale"
  property int selectedIndex: 0
  property bool cursorActive: false
  // Scale is now a slider like text size: while a change is in flight, the
  // chosen stop index overrides the live monitorScale-derived index so the
  // knob doesn't snap back during the omarchy-hyprland-monitor-scaling
  // round-trip. -1 = no pending change; follow activeScaleIndex().
  property int scalePreviewIndex: -1

  // Text size slider — curated macOS-style notches (px). The panel snaps to
  // these stops; the CLI (omarchy-display-text-size) accepts any integer in range.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // While a change is in flight, the chosen stop index overrides the live
  // base-size so the knob doesn't snap back during the file round-trip. -1 =
  // no pending change; follow Style.font.baseSize.
  property int textSizePreviewIndex: -1

  // A text-size change reflows the whole panel (both font and spacing scale),
  // which slides rows under a stationary pointer and fires synthetic hover.
  // While true, hover is not allowed to hijack the keyboard focus section —
  // otherwise h/l on the text-size slider can jump focus to another row.
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  // Screensaver idle-timeout slider — same curated-stops feel as text size,
  // in seconds. Reads/writes shell.json's idle.screensaver directly via
  // bar.shell.mutateShellConfig; no CLI round-trip, so no preview index needed.
  readonly property var screensaverStops: [30, 60, 120, 180, 300, 600, 900, 1800]

  readonly property int screensaverSeconds: {
    var cfg = root.bar && root.bar.shell ? root.bar.shell.shellConfig : null
    var idle = cfg && cfg.idle ? cfg.idle : null
    var v = idle && idle.screensaver !== undefined ? Number(idle.screensaver) : NaN
    return isFinite(v) && v >= 0 ? Math.floor(v) : 150
  }

  function currentScreensaverIndex() {
    return Model.nearestStopIndex(screensaverStops, screensaverSeconds)
  }

  function screensaverStopLabel(index) {
    var i = Math.max(0, Math.min(screensaverStops.length - 1, Math.round(index)))
    return Model.formatDuration(screensaverStops[i])
  }

  function setScreensaverSeconds(seconds) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.mutateShellConfig !== "function") return
    root.bar.shell.mutateShellConfig(function(config) {
      if (!config.idle || typeof config.idle !== "object") config.idle = {}
      config.idle.screensaver = seconds
    })
  }

  function adjustScreensaver(deltaSteps) {
    var idx = currentScreensaverIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > screensaverStops.length - 1) idx = screensaverStops.length - 1
    setScreensaverSeconds(screensaverStops[idx])
  }

  readonly property var visibleSections: {
    // "restart" first: its control now sits in the hero's top-right
    // corner, above everything else visually.
    var list = ["restart"]
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize")
    list.push("screensaver")
    list.push("scale")
    if (refreshRateOptions.length > 1) list.push("refreshrate")
    if (showMirrorSection) list.push("mirror")
    list.push("cursorsize")
    if (displays.length > 1) list.push("monitors")
    return list
  }

  function restartShell() {
    if (!restartShellProc.running) restartShellProc.running = true
  }

  function sectionCount(section) {
    if (section === "brightness") return 0  // only the slider sentinel at -1
    if (section === "textsize") return 0    // slider sentinel at -1, like brightness
    if (section === "scale") return 0       // slider sentinel at -1, like text size
    if (section === "refreshrate") return 0   // dropdown sentinel at -1
    if (section === "mirror") return mirrorOptions.length
    if (section === "monitors") return displays.length
    if (section === "cursorsize") return cursorSizeOptions.length
    if (section === "restart") return 1
    return 0
  }

  function sectionIsSingleRow(section) {
    // Lone sliders/dropdowns and horizontal option rows are "single row"
    // from j/k's perspective (h/l or the dropdown's own popup handles
    // movement within them). "monitors" is a vertical list of rows instead.
    return section === "brightness" || section === "textsize" || section === "scale"
      || section === "screensaver" || section === "refreshrate" || section === "mirror"
      || section === "cursorsize"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "textsize" || section === "scale" || section === "screensaver"
        || section === "refreshrate") return -1
    return 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (delta > 0) {
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        // Coming up from below — land on the last navigable row of the prev
        // section, or its sentinel for single-row sections.
        selectedIndex = sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  // h/l: walks the horizontal option row for mirror/cursor-size; everywhere
  // else a no-op (scale/brightness/text size have their own adjust
  // functions; dropdowns own their popup's j/k once open).
  function moveCursorH(delta) {
    var max
    if (focusSection === "mirror") max = mirrorOptions.length - 1
    else if (focusSection === "cursorsize") max = cursorSizeOptions.length - 1
    else return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > max) next = max
    selectedIndex = next
  }

  function adjustBrightness(delta) {
    if (focusSection !== "brightness") return
    if (!brightnessAvailable) return
    setBrightness(root.brightnessPercent + delta)
  }

  function activateCursor() {
    if (focusSection === "mirror" && selectedIndex >= 0 && selectedIndex < mirrorOptions.length) {
      setMirror(mirrorOptions[selectedIndex])
      return
    }
    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {
      var d = displays[selectedIndex]
      if (d) toggleDisplay(d.name, d.enabled)
      return
    }
    if (focusSection === "cursorsize" && selectedIndex >= 0 && selectedIndex < cursorSizeOptions.length) {
      setCursorSize(cursorSizeOptions[selectedIndex])
      return
    }
    if (focusSection === "refreshrate") {
      refreshRateDropdown.open()
      return
    }
    if (focusSection === "restart" && selectedIndex === 0) {
      restartShell()
      return
    }
    // brightness: no separate action; the slider value is the action.
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var count = sectionCount(focusSection)
    if (sectionIsSingleRow(focusSection)) {
      // brightness/text size/scale/screensaver/refresh rate use the -1
      // sentinel; mirror/cursor-size clamp into their option row.
      if (focusSection === "brightness" || focusSection === "textsize" || focusSection === "scale" || focusSection === "screensaver"
          || focusSection === "refreshrate") selectedIndex = -1
      else if (selectedIndex < 0 || selectedIndex >= count) selectedIndex = 0
      return
    }
    if (count === 0) {
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // Keep the keyboard-focused row inside the viewport when the panel grows
  // taller than its allotted height (lots of displays). Mirrors audio's
  // ensureCursorVisible helper.
  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    var value = Number(percent)
    root.setBrightness(value)
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      focusedMonitor: root.focusedMonitor,
      scale: root.monitorScale,
      displays: root.displays
    })
  }

  IpcHandler {
    target: "omarchy.monitor"

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
    if (!monitorInfoProc.running) monitorInfoProc.running = true
    if (!cursorInfoProc.running) cursorInfoProc.running = true
  }

  function updateMonitorInfo(json) {
    var parsed = Model.parseMonitorInfo(json)
    root.monitorLabels = parsed.labels
    root.monitorInfoList = parsed.list
    root.monitorInfoByName = parsed.byName
    fixAnyOverlap()
  }

  // Self-healing safety net, independent of drag/rotate: confirmed live
  // that Hyprland's own "auto" placement (monitors.lua's wildcard rule) can
  // produce an overlapping layout on its own after an unrelated config
  // reload — not something a fix scoped to this panel's own actions can
  // prevent. Runs on every refresh (every 5s while open, plus right after
  // any action here completes) and silently corrects any overlap found
  // among enabled displays, whoever/whatever caused it.
  function fixAnyOverlap() {
    if (root.arrangementDragActive) return
    var infos = []
    for (var i = 0; i < root.monitorInfoList.length; i++) {
      if (!root.monitorInfoList[i].disabled) infos.push(root.monitorInfoList[i])
    }
    var rectsByName = {}
    for (var j = 0; j < infos.length; j++) {
      var f = root.monitorFootprint(infos[j])
      rectsByName[infos[j].name] = { x: infos[j].x, y: infos[j].y, w: f.w, h: f.h }
    }
    for (var k = 0; k < infos.length; k++) {
      var name = infos[k].name
      var target = rectsByName[name]
      var others = []
      for (var m = 0; m < infos.length; m++) {
        if (infos[m].name !== name) others.push(rectsByName[infos[m].name])
      }
      var resolved = Model.resolveMonitorOverlap(target, others)
      if (resolved.x !== target.x || resolved.y !== target.y) {
        rectsByName[name] = { x: resolved.x, y: resolved.y, w: target.w, h: target.h }
        applyMonitor(withOverrides(infos[k], { x: resolved.x, y: resolved.y }))
      }
    }
  }

  function friendlyDisplayName(display) {
    if (!display) return ""
    var label = root.monitorLabels[display.name]
    return label || display.name
  }

  // "3440 × 1440 @ 165 Hz" — native resolution, not the logical/rotated
  // footprint used elsewhere (Arrangement, cursor-size scaling), since
  // "what resolution is this panel" conventionally means its own physical
  // pixels regardless of current rotation. Falls back to the width/height
  // already on `display` (from omarchy-monitor-state) if the richer
  // monitorInfoByName fetch hasn't populated yet, dropping refresh rate
  // (only available from the richer fetch) in that case.
  function displayResolutionLabel(display) {
    if (!display) return ""
    var info = root.monitorInfoByName[display.name]
    var w = info ? info.width : display.width
    var h = info ? info.height : display.height
    if (!w || !h) return ""
    var label = w + " × " + h
    if (info && info.refreshRate) label += " @ " + Model.formatHz(info.refreshRate)
    return label
  }

  // Hero title: the focused display's friendly name, falling back to the
  // generic label before the first monitorInfo fetch resolves.
  readonly property string heroTitle: {
    var info = root.monitorInfoByName[root.focusedMonitor]
    return info ? info.label : "Display"
  }

  // gsettings stores the logical size we last sent hyprctl, not the physical
  // target the options represent (see setCursorSize) — convert back and
  // snap to the nearest known option so the button group's highlight lines
  // up exactly despite rounding in the logical<->physical round trip.
  function updateCursorSize(text) {
    var n = parseInt(String(text || "").trim(), 10)
    if (!isFinite(n) || n <= 0) return
    var scale = Number(root.monitorScale) || 1
    var physical = n * scale
    var options = root.cursorSizeOptions.map(function(v) { return Number(v) })
    root.cursorSize = Model.nearestRate(options, physical)
  }

  // Shallow-copy-with-overrides, used to build an updated monitor call from
  // a cached info object without mutating it in place.
  function withOverrides(info, overrides) {
    var copy = {}
    for (var k in info) copy[k] = info[k]
    for (var k2 in overrides) copy[k2] = overrides[k2]
    return copy
  }

  // Omarchy's monitor config is applied through a Lua layer (~/.config/hypr/
  // monitors.lua calls hl.monitor({...})), not plain hyprland.conf keywords —
  // `hyprctl keyword monitor ...` fails outright here ("keyword can't work
  // with non-legacy parsers. Use eval."). The live mechanism is `hyprctl eval`
  // with a Lua call to the same hl.monitor() function, exactly like the
  // stock omarchy-hyprland-monitor-scaling script does. This only applies
  // live; it doesn't persist across reboots the way monitors.lua does.
  function monitorEvalExpr(info) {
    // transform must always be sent explicitly, even when 0: like disabled
    // (see toggleDisplay), hl.monitor() appears to merge rather than
    // replace, so omitting a falsy property leaves its previous value
    // instead of resetting it — confirmed live (rotating to 0° silently
    // did nothing when this was conditional).
    var lua = 'hl.monitor({ output = "' + info.name + '"'
      + ', mode = "' + info.width + 'x' + info.height + '@' + info.refreshRate + '"'
      + ', position = "' + info.x + 'x' + info.y + '"'
      + ', scale = ' + info.scale
      + ', transform = ' + info.transform
      + ' })'
    return lua
  }

  function applyMonitor(info) {
    runAction(["hyprctl", "eval", monitorEvalExpr(info)])
  }

  // ---- Refresh rate: focused display only, same convention as Scale ----
  function focusedMonitorInfo() {
    return root.monitorInfoByName[root.focusedMonitor] || null
  }

  readonly property var refreshRateOptions: {
    var info = focusedMonitorInfo()
    if (!info) return []
    var rates = Model.refreshRatesFor(info.availableModes, info.width, info.height)
    var opts = []
    for (var i = 0; i < rates.length; i++) opts.push({ value: String(rates[i]), label: Model.formatHz(rates[i]) })
    return opts
  }

  readonly property string refreshRateValue: {
    var info = focusedMonitorInfo()
    if (!info) return ""
    var rates = Model.refreshRatesFor(info.availableModes, info.width, info.height)
    var nearest = Model.nearestRate(rates, info.refreshRate)
    return isFinite(nearest) ? String(nearest) : ""
  }

  function setRefreshRate(value) {
    var info = focusedMonitorInfo()
    if (!info) return
    var rate = Number(value)
    if (!isFinite(rate)) return
    applyMonitor(withOverrides(info, { refreshRate: rate }))
  }

  // ---- Mirror / Extend: only meaningful for a laptop + external pair ----
  readonly property bool showMirrorSection: root.internalMonitor !== "" && root.externalMonitor !== ""
  readonly property var mirrorOptions: ["Extend", "Mirror"]
  readonly property string mirrorValue: root.mirrorEnabled ? "Mirror" : "Extend"

  function setMirror(value) {
    runAction(["omarchy-hyprland-monitor-internal-mirror", value === "Mirror" ? "on" : "off"])
  }

  // ---- Arrangement diagram + per-display rotation (Displays list) ----
  readonly property var enabledMonitorInfos: Model.orderedEnabledMonitors(root.monitorInfoList)
  readonly property bool showArrangementSection: enabledMonitorInfos.length > 1
  readonly property var rotationOptions: [
    { value: "0", label: "0°" },
    { value: "1", label: "90°" },
    { value: "2", label: "180°" },
    { value: "3", label: "270°" }
  ]

  // Logical (physical / scale) footprint, with 90°/270° swapping width and
  // height — the on-screen size a rotated display actually occupies.
  function monitorFootprint(info) {
    var s = info.scale > 0 ? info.scale : 1
    var lw = info.width / s
    var lh = info.height / s
    var rotated = info.transform === 1 || info.transform === 3
    return rotated ? { w: lh, h: lw } : { w: lw, h: lh }
  }

  function setTransform(name, value) {
    var info = root.monitorInfoByName[name]
    if (!info) return
    var updated = withOverrides(info, { transform: Number(value) })
    var footprint = monitorFootprint(updated)

    // Rotating swaps this display's footprint without moving its x/y,
    // which can silently overlap a neighbor that was flush against it
    // before — nudge it clear rather than let that reach Hyprland (it
    // rejects overlapping layouts with a "will cause issues" warning).
    var others = []
    for (var i = 0; i < root.monitorInfoList.length; i++) {
      var m = root.monitorInfoList[i]
      if (m.disabled || m.name === name) continue
      var f = monitorFootprint(m)
      others.push({ x: m.x, y: m.y, w: f.w, h: f.h })
    }
    var pos = Model.resolveMonitorOverlap({ x: info.x, y: info.y, w: footprint.w, h: footprint.h }, others)

    applyMonitor(withOverrides(updated, { x: pos.x, y: pos.y }))
  }

  // ---- Cursor size: live via hyprctl, persisted via gsettings so GTK apps
  // and the next session pick it up too ----
  //
  // These are the *physical* on-screen sizes this specific cursor theme
  // (Adwaita, inherited by the "default" XCursor theme) actually ships as
  // distinct raster images — parsed from its XCursor binary. hyprctl
  // setcursor takes a *logical* size and multiplies by the monitor's scale
  // before picking the nearest shipped raster; without correcting for that,
  // every option above the theme's max (96) collapses onto the same asset,
  // and the collapsed band grows with scale. Dividing by scale below keeps
  // each option's physical result exact regardless of scale. If the active
  // cursor theme changes, its own raster set may differ from these.
  readonly property var cursorSizeOptions: ["24", "30", "36", "48", "72", "96"]

  function setCursorSize(physicalSize) {
    var desired = Math.round(Number(physicalSize))
    if (!isFinite(desired) || desired <= 0) return
    var scale = Number(root.monitorScale) || 1
    var logical = Math.max(1, Math.round(desired / scale))
    root.cursorSize = desired
    actionProc.command = ["bash", "-lc",
      "theme=$(gsettings get org.gnome.desktop.interface cursor-theme | tr -d \"'\"); "
      + "gsettings set org.gnome.desktop.interface cursor-size " + logical + "; "
      + "hyprctl setcursor \"$theme\" " + logical]
    if (!actionProc.running) actionProc.running = true
  }

  function setBrightness(value) {
    var percent = Model.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, percent + "%"]
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Model.clampBrightness(value)
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  function normalizeScale(scale) {
    return Model.normalizeScale(scale)
  }

  function activeScaleIndex() {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.matchingScaleIndex(scaleValues, monitorScale, display.width, display.height)
    }
    return -1
  }

  function effectiveScale(scale) {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.cleanScale(scale, display.width, display.height)
    }
    return normalizeScale(scale)
  }

  // Playful mood-name for a given brightness percent. Bands intentionally
  // span ~10–20 points so casual tweaks change the label, while small
  // nudges within one band don't.
  function brightnessName(percent) {
    return Model.brightnessName(percent)
  }

  function updateDisplays(displaysJson) {
    var parsed = Model.parseDisplays(displaysJson)
    root.displays = parsed.displays
    root.enabledDisplayCount = parsed.enabledDisplayCount
  }

  function toggleDisplay(name, enabled) {
    if (!name) return
    if (enabled && root.enabledDisplayCount <= 1) return

    var lua
    if (enabled) {
      lua = 'hl.monitor({ output = "' + name + '", disabled = true })'
    } else {
      // disabled must be set explicitly false to re-enable — omitting it
      // leaves a previously-disabled monitor disabled (confirmed live).
      var info = root.monitorInfoByName[name]
      var scale = info && info.scale ? info.scale : 1
      lua = 'hl.monitor({ output = "' + name + '", mode = "preferred", position = "auto", scale = ' + scale + ', disabled = false })'
    }
    runAction(["hyprctl", "eval", lua])
  }

  function setScale(scale) {
    // omarchy-hyprland-monitor-scaling's own hl.monitor call hardcodes
    // position = "auto" — harmless normally, but it silently discarded a
    // careful drag-arranged layout every time scale changed. Capture this
    // display's position first and restore it once the (stock, unmodified)
    // scaling script has done its clean-scale rounding + monitors.lua
    // persistence, using whatever mode/scale it actually landed on.
    var focused = focusedMonitorInfo()
    if (!focused) { runAction(["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale]); return }
    var name = focused.name
    var restoreLua = 'hl.monitor({ output = "' + name + '", mode = "${w}x${h}@${rate}", position = "'
      + focused.x + 'x' + focused.y + '", scale = ${sc} })'
    var script = "omarchy-hyprland-monitor-scaling " + scale + " && "
      + "info=$(hyprctl monitors -j | jq -e -c " + JSON.stringify('.[] | select(.name=="' + name + '")') + ") && "
      + "w=$(jq -r .width <<< \"$info\") && h=$(jq -r .height <<< \"$info\") && "
      + "rate=$(jq -r .refreshRate <<< \"$info\") && sc=$(jq -r .scale <<< \"$info\") && "
      + "hyprctl eval " + JSON.stringify(restoreLua)
    runAction(["bash", "-c", script])
  }

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise wherever monitorScale currently matches (clamped, since a
  // slider position can't render -1 "no match").
  function currentScaleIndex() {
    if (scalePreviewIndex >= 0) return scalePreviewIndex
    return Math.max(0, activeScaleIndex())
  }

  function adjustScale(deltaSteps) {
    var idx = currentScaleIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > scaleValues.length - 1) idx = scaleValues.length - 1
    scalePreviewIndex = idx
    setScale(scaleValues[idx])
  }

  // Once monitorScale catches up to the pending choice, drop the preview so
  // the slider tracks the live value again.
  onMonitorScaleChanged: {
    if (scalePreviewIndex >= 0 && activeScaleIndex() === scalePreviewIndex) scalePreviewIndex = -1
  }

  // ---- Text size (shell base font + GTK text-scaling, via one CLI) ----
  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise whatever Style's live base-size rounds to.
  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  // px shown in the header: the pending stop if any, else the true base-size
  // (which may be an off-notch value set from the CLI).
  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = currentTextIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > textSizeStops.length - 1) idx = textSizeStops.length - 1
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    refresh()
    reopenCheckProc.command = ["bash", "-lc",
      "f=\"" + reopenMarkerPath() + "\"; [ -f \"$f\" ] && rm -f \"$f\" && echo yes || true"]
    reopenCheckProc.running = true
  }

  // KeyboardPanel primes focus at open-time, so SUPER-bound IPC summons land
  // with j/k ready to navigate. Keep a default landing point, but don't paint
  // the cursor until hover or the first navigation key.
  onOpenedChanged: {
    if (opened) {
      refresh()
      if (brightnessAvailable) {
        focusSection = "brightness"
        selectedIndex = -1
      } else {
        focusSection = "scale"
        selectedIndex = 0
      }
      cursorActive = false
    } else if (root.pendingReopen) {
      // A monitor action (scale, position, ...) forced this popup's own
      // window closed as a side effect of Hyprland notifying clients of
      // the geometry change — the component instance survives (this isn't
      // a full quickshell restart), so reacting here catches what the
      // file-marker/Component.onCompleted path only catches when the
      // whole process actually restarts (see runAction below).
      root.pendingReopen = false
      pendingReopenExpire.stop()
      reopenSettle.restart()
    }
  }

  Timer {
    id: reopenSettle
    interval: 150
    repeat: false
    onTriggered: root.open()
  }

  // Drops a stale pendingReopen if the action never actually closed the
  // panel, so a much-later manual close doesn't get reopened by mistake.
  Timer {
    id: pendingReopenExpire
    interval: 2000
    repeat: false
    onTriggered: root.pendingReopen = false
  }

  onBrightnessAvailableChanged: clampCursor()
  onDisplaysChanged: clampCursor()
  onScaleValuesChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()

  // Only poll while the panel is open; the bar glyph tracks monitor count via
  // Quickshell.screens, and open-time refresh + Component.onCompleted cover the
  // rest. External brightness changes are reflected whenever the panel is open.
  Timer {
    interval: 5000
    running: root.opened && !root.arrangementDragActive
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        root.brightnessAvailable = brightness !== "unavailable" && brightness !== ""
        root.brightnessPercent = root.brightnessAvailable ? Math.max(0, Math.min(100, parseInt(brightness, 10))) : 0
        root.internalMonitor = String(lines[1] || "").trim()
        root.externalMonitor = String(lines[2] || "").trim()
        root.internalEnabled = String(lines[3] || "").trim() !== ""
        root.mirrorEnabled = String(lines[4] || "").trim() === root.externalMonitor && root.externalMonitor !== ""
        root.focusedMonitor = String(lines[5] || "").trim()
        root.monitorScale = root.normalizeScale(String(lines[6] || "").trim())
        root.updateDisplays(String(lines[7] || "[]").trim())
      }
    }
  }

  // omarchy-monitor-state (shared, read-only) doesn't carry EDID make/model/
  // description, so this clone fetches it separately rather than patching
  // that packaged script.
  Process {
    id: monitorInfoProc
    command: ["bash", "-lc", "hyprctl monitors all -j | jq -c '[.[] | {name, make, model, description, x, y, width, height, refreshRate, scale, transform, disabled, focused, availableModes}]'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateMonitorInfo(String(text || "[]").trim())
    }
  }

  Process {
    id: cursorInfoProc
    command: ["gsettings", "get", "org.gnome.desktop.interface", "cursor-size"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateCursorSize(text)
    }
  }

  // Fire-and-forget: omarchy-restart-shell forks the replacement via
  // hyprctl before killing this process, and keeps running as an
  // independent child even after this quickshell instance exits mid-script.
  //
  // Guarded with flock rather than restartShellProc.running: that QML
  // property only prevents a double-click within one running instance. If a
  // second click lands on the freshly-restarted panel while the *previous*
  // restart-shell invocation is still in its post-relaunch poll loop, that
  // in-memory flag has already reset to false in the new process — nothing
  // stops a second `quickshell kill -p ...` from matching (it filters by
  // config path, not a specific instance) and killing the brand-new
  // replacement with no third invocation left to bring it back. The lock
  // file is real cross-process state, so the second attempt just no-ops
  // instead of racing the first.
  Process {
    id: restartShellProc
    command: ["bash", "-lc", "flock -n \"${XDG_RUNTIME_DIR:-/tmp}/omarchy-shell-restart.lock\" omarchy-restart-shell"]
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    // Do NOT call refresh() after a brightness set completes. The local
    // brightnessPercent we just wrote is authoritative; re-reading via
    // `omarchy-brightness-display` races the hardware/driver and can
    // return an empty string, which the parser then coerces to 0 —
    // visible as a "bounce to zero" after h/l keypresses. External
    // brightness changes are still picked up by the 5s periodic refresh,
    // the open-time refresh, and Component.onCompleted.
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent)
      }
    }
  }

  // Monitor actions (scale, position, rotation, enable/disable, ...) can
  // force this popup's window closed while it's open, as a side effect of
  // Hyprland notifying clients of the geometry change — confirmed this
  // happens even for a plain scale/position change that never restarts
  // quickshell at all. Two reopen paths, for the two ways that can play
  // out: pendingReopen (in-memory, consumed by onOpenedChanged) handles
  // the common case where this component instance survives and just had
  // its window closed out from under it; the file marker below handles
  // the rarer case where the whole process actually restarts, wiping any
  // in-memory state, and only Component.onCompleted (reopenCheckProc) on
  // the fresh instance can see it.
  //
  // Each monitor's bar carries its own instance of this whole widget (one
  // KeyboardPanel per screen), so the marker's *filename* embeds this
  // instance's own screen name — confirmed live that a single shared
  // filename lets whichever monitor's instance finishes loading first win
  // the race and reopen itself, regardless of which one was actually open.
  function panelScreenName() {
    var name = (panel && panel.screen) ? String(panel.screen.name || "") : ""
    var safe = name.replace(/[^A-Za-z0-9._-]/g, "_")
    return safe || "unknown"
  }

  function reopenMarkerPath() {
    return "${XDG_RUNTIME_DIR:-/tmp}/omarchy-monitor-panel-reopen." + panelScreenName()
  }

  function runAction(command) {
    if (root.opened) {
      root.pendingReopen = true
      pendingReopenExpire.restart()
      markReopenProc.command = ["bash", "-lc", "touch \"" + reopenMarkerPath() + "\""]
      if (!markReopenProc.running) markReopenProc.running = true
    }
    actionProc.command = command
    if (!actionProc.running) actionProc.running = true
  }

  Process {
    id: markReopenProc
  }

  Process {
    id: reopenCheckProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text).trim() === "yes") root.open()
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    // Settle before refreshing rather than querying state the instant the
    // command exits: hyprctl can acknowledge a monitor change and exit
    // before Hyprland has actually finished reflowing the layout, so an
    // immediate `hyprctl monitors -j` can read stale positions — and
    // fixAnyOverlap() acting on that stale read could "correct" a display
    // that was never actually overlapping, undoing a just-completed drag.
    onRunningChanged: if (!running) actionSettleTimer.restart()
  }

  Timer {
    id: actionSettleTimer
    interval: 150
    repeat: false
    onTriggered: root.refresh()
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch, so there's
  // nothing to refresh here.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Clears the hover-suppression flag once the reflow triggered by a text-size
  // change has settled.
  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  // Once Style's base-size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again. The change itself reflows the
  // panel, so suppress hover for a beat while it lands.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightnessPercent + wheel.steps * 5)
      root.showBrightnessOsd(root.brightnessPercent)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Widened from the stock 380 for the two-column settings grid.
    contentWidth: panel.fittedContentWidth(Style.space(560))
    // Raised again for the two-column settings grid (refresh rate, mirror,
    // cursor size, arrangement); still a real cap, not just
    // "size to content", so a many-monitor Displays/Arrangement list can't
    // grow the panel past a sane height on a short screen.
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(1200))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Suspend our own j/k/h/l handling while a Dropdown's popup owns the
      // keyboard — its internal list has its own j/k + Enter. Driven by
      // plain root properties rather than reaching for a Dropdown by id,
      // since they live behind conditionally-visible/repeated cards this
      // binding can evaluate before they exist.
      blocked: root.refreshRateDropdownOpen || root.openRotationDropdownCount > 0
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "textsize") root.adjustTextSize(dx)
          else if (root.focusSection === "scale") root.adjustScale(dx)
          else if (root.focusSection === "mirror") root.moveCursorH(dx)
          else if (root.focusSection === "cursorsize") root.moveCursorH(dx)
          else if (root.focusSection === "screensaver") root.adjustScreensaver(dx)
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: display icon · title/status ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.displays.length > 1 ? "󰍺" : "󰍹"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            PanelActionButton {
              id: restartShellAction
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰑐"
              tooltipText: "Restart Omarchy Shell"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              hasCursor: root.cursorActive && root.focusSection === "restart" && root.selectedIndex === 0

              onClicked: root.restartShell()
              onHovered: function(isHovered) {
                if (!isHovered || root.reflowingText) return
                root.cursorActive = true
                root.focusSection = "restart"
                root.selectedIndex = 0
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: restartShellAction.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: root.heroTitle
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                textFormat: Text.PlainText
                text: {
                  if (root.brightnessAvailable) {
                    return root.brightnessName(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent).toUpperCase()
                  }
                  return "FIXED BRIGHTNESS"
                }
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          PanelSeparator {
            foreground: root.bar.foreground
          }

          GridLayout {
            id: settingsGrid
            width: parent.width
            columns: 2
            columnSpacing: Style.space(18)
            rowSpacing: Style.space(16)

            // ---------- Brightness ----------
            Column {
              Layout.fillWidth: true
              visible: root.brightnessAvailable
              spacing: Style.space(6)

              Item {
                width: parent.width
                implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercent.implicitHeight)

                PanelSectionHeader {
                  id: brightnessHeader
                  text: "BRIGHTNESS"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: brightnessPercent
                  textFormat: Text.PlainText
                  text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent) + "%"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              CursorSurface {
                id: brightnessRow
                width: parent.width
                height: brightnessSlider.implicitHeight + Style.spacing.controlGap
                hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
                foreground: root.bar.foreground
                outline: true

                PanelSlider {
                  id: brightnessSlider
                  bar: root.bar
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  minimum: 1
                  maximum: 100
                  step: 1
                  value: root.brightnessPercent
                  integer: true
                  onMoved: function(v) { root.previewBrightness(v) }
                  onReleased: function(v) {
                    brightnessDebounce.stop()
                    root.setBrightness(v)
                  }
                }

                HoverHandler {
                  onHoveredChanged: if (hovered && !root.reflowingText) {
                    root.cursorActive = true
                    root.focusSection = "brightness"
                    root.selectedIndex = -1
                  }
                }
              }
            }

            // ---------- Text size ----------
            Column {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Item {
                width: parent.width
                implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

                PanelSectionHeader {
                  id: textSizeHeader
                  text: "TEXT SIZE"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: textSizePx
                  textFormat: Text.PlainText
                  text: (textSizeSlider.dragging
                         ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                         : root.displayedTextPx()) + "px"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              CursorSurface {
                id: textSizeRow
                width: parent.width
                height: textSizeSlider.implicitHeight + Style.spacing.controlGap
                hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
                foreground: root.bar.foreground
                outline: true

                PanelSlider {
                  id: textSizeSlider
                  bar: root.bar
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  minimum: 0
                  maximum: root.textSizeStops.length - 1
                  step: 1
                  integer: true
                  tickCount: root.textSizeStops.length
                  value: root.currentTextIndex()
                  onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
                }

                HoverHandler {
                  onHoveredChanged: if (hovered && !root.reflowingText) {
                    root.cursorActive = true
                    root.focusSection = "textsize"
                    root.selectedIndex = -1
                  }
                }
              }
            }

            // ---------- Screensaver ----------
            Column {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Item {
                width: parent.width
                implicitHeight: Math.max(screensaverHeader.implicitHeight, screensaverValue.implicitHeight)

                PanelSectionHeader {
                  id: screensaverHeader
                  text: "SCREENSAVER"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: screensaverValue
                  textFormat: Text.PlainText
                  text: root.screensaverStopLabel(screensaverSlider.dragging ? screensaverSlider.liveValue : root.currentScreensaverIndex())
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              CursorSurface {
                id: screensaverRow
                width: parent.width
                height: screensaverSlider.implicitHeight + Style.spacing.controlGap
                hasCursor: root.cursorActive && root.focusSection === "screensaver" && root.selectedIndex === -1
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(screensaverRow)
                foreground: root.bar.foreground
                outline: true

                PanelSlider {
                  id: screensaverSlider
                  bar: root.bar
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  minimum: 0
                  maximum: root.screensaverStops.length - 1
                  step: 1
                  integer: true
                  tickCount: root.screensaverStops.length
                  value: root.currentScreensaverIndex()
                  onReleased: function(v) { root.setScreensaverSeconds(root.screensaverStops[Math.round(v)]) }
                }

                HoverHandler {
                  onHoveredChanged: if (hovered && !root.reflowingText) {
                    root.cursorActive = true
                    root.focusSection = "screensaver"
                    root.selectedIndex = -1
                  }
                }
              }
            }

            // ---------- Scale ----------
            // A slider like text size, applying only to the focused
            // display — same convention the old button-row version used.
            Column {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Item {
                width: parent.width
                implicitHeight: Math.max(scaleHeader.implicitHeight, scaleValueText.implicitHeight)

                PanelSectionHeader {
                  id: scaleHeader
                  text: "SCALE"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: scaleValueText
                  textFormat: Text.PlainText
                  text: root.effectiveScale(root.scaleValues[Math.round(scaleSlider.dragging ? scaleSlider.liveValue : root.currentScaleIndex())]) + "x"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              CursorSurface {
                id: scaleRow
                width: parent.width
                height: scaleSlider.implicitHeight + Style.spacing.controlGap
                hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === -1
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(scaleRow)
                foreground: root.bar.foreground
                outline: true

                PanelSlider {
                  id: scaleSlider
                  bar: root.bar
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  minimum: 0
                  maximum: root.scaleValues.length - 1
                  step: 1
                  integer: true
                  tickCount: root.scaleValues.length
                  value: root.currentScaleIndex()
                  onReleased: function(v) { root.setScale(root.scaleValues[Math.round(v)]) }
                }

                HoverHandler {
                  onHoveredChanged: if (hovered && !root.reflowingText) {
                    root.cursorActive = true
                    root.focusSection = "scale"
                    root.selectedIndex = -1
                  }
                }
              }
            }

            // ---------- Refresh rate (focused display) ----------
            Column {
              Layout.fillWidth: true
              visible: root.refreshRateOptions.length > 1
              spacing: Style.space(6)

              PanelSectionHeader {
                text: "REFRESH RATE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              Dropdown {
                id: refreshRateDropdown
                width: parent.width
                showLabel: false
                options: root.refreshRateOptions
                value: root.refreshRateValue
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                hasCursor: root.cursorActive && root.focusSection === "refreshrate" && root.selectedIndex === -1
                onPopupOpenChanged: root.refreshRateDropdownOpen = popupOpen
                onChanged: function(v) { root.setRefreshRate(v) }
                onHovered: function(isHovered) {
                  if (!isHovered || root.reflowingText) return
                  root.cursorActive = true
                  root.focusSection = "refreshrate"
                  root.selectedIndex = -1
                }
              }
            }

            // ---------- Mirror / Extend (laptop + external only) ----------
            Column {
              Layout.fillWidth: true
              visible: root.showMirrorSection
              spacing: Style.space(6)

              PanelSectionHeader {
                text: "MIRROR"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              ButtonGroup {
                options: root.mirrorOptions
                value: root.mirrorValue
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                cursorIndex: root.cursorActive && root.focusSection === "mirror" ? root.selectedIndex : -1
                onChanged: function(v) { root.setMirror(v) }
                onHovered: function(index, isHovered) {
                  if (!isHovered || root.reflowingText) return
                  root.cursorActive = true
                  root.focusSection = "mirror"
                  root.selectedIndex = index
                }
              }
            }

            // ---------- Cursor size ----------
            Column {
              Layout.fillWidth: true
              Layout.columnSpan: 2
              spacing: Style.space(6)

              PanelSectionHeader {
                text: "CURSOR SIZE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              ButtonGroup {
                options: root.cursorSizeOptions
                value: String(root.cursorSize)
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                cursorIndex: root.cursorActive && root.focusSection === "cursorsize" ? root.selectedIndex : -1
                onChanged: function(v) { root.setCursorSize(v) }
                onHovered: function(index, isHovered) {
                  if (!isHovered || root.reflowingText) return
                  root.cursorActive = true
                  root.focusSection = "cursorsize"
                  root.selectedIndex = index
                }
              }
            }

            // ---------- Monitors ----------
            Column {
              Layout.fillWidth: true
              Layout.columnSpan: 2
              spacing: Style.space(10)
              visible: root.displays.length > 1

              PanelSectionHeader {
                text: "DISPLAYS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              Repeater {
                model: root.displays

                MonitorRow {
                  required property var modelData
                  required property int index

                  width: panelColumn.width
                  display: modelData
                  rowIndex: index
                }
              }
            }

            // ---------- Arrangement ----------
            Column {
              Layout.fillWidth: true
              Layout.columnSpan: 2
              visible: root.showArrangementSection
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "ARRANGEMENT"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              ArrangementDiagram {
                width: parent.width
              }
            }

          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  component MonitorRow: CursorSurface {
    id: monitorRow
    required property var display
    required property int rowIndex

    readonly property bool isFocused: display && display.focused
    readonly property bool canToggle: display && (!display.enabled || root.enabledDisplayCount > 1)
    readonly property var info: display ? root.monitorInfoByName[display.name] : null

    hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(monitorRow)
    current: isFocused
    foreground: root.bar.foreground
    fill: Style.hoverFillFor(root.bar.foreground, Color.accent)
    currentFill: Style.selectedFillFor(root.bar.foreground, Color.accent)
    implicitHeight: monitorInner.implicitHeight + Style.spacing.xl
    opacity: canToggle ? 1.0 : 0.45

    Row {
      id: monitorInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: "󰍹"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: parent.width - Style.space(22) - rotationDropdown.width - toggleButton.width - Style.space(24)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          text: root.friendlyDisplayName(monitorRow.display) + (monitorRow.display.focused ? " · focused" : "")
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          textFormat: Text.PlainText
          text: root.displayResolutionLabel(monitorRow.display)
          visible: text !== ""
          color: Qt.darker(root.bar.foreground, 1.6)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }

      Dropdown {
        id: rotationDropdown
        width: Style.space(84)
        showLabel: false
        options: root.rotationOptions
        value: monitorRow.info ? String(monitorRow.info.transform) : "0"
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        anchors.verticalCenter: parent.verticalCenter
        onPopupOpenChanged: root.openRotationDropdownCount += popupOpen ? 1 : -1
        onChanged: function(v) { root.setTransform(monitorRow.display.name, v) }
      }

      Button {
        id: toggleButton
        text: monitorRow.display.enabled ? "Turn Off" : "Turn On"
        fontSize: Style.font.caption
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        horizontalPadding: Style.spacing.sm
        verticalPadding: Style.spacing.labelGap
        bordered: true
        enabled: monitorRow.canToggle
        opacity: enabled ? 1.0 : 0.4
        hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === monitorRow.rowIndex

        onClicked: root.toggleDisplay(monitorRow.display.name, monitorRow.display.enabled)
        onHovered: function(isHovered) {
          if (!isHovered || root.reflowingText) return
          root.cursorActive = true
          root.focusSection = "monitors"
          root.selectedIndex = monitorRow.rowIndex
        }
      }
    }

    // HoverHandler, not a MouseArea: the row now owns an interactive Button
    // rather than being one big click target, so this only syncs the
    // keyboard cursor to mouse hover without swallowing the button's clicks.
    HoverHandler {
      onHoveredChanged: if (hovered && !root.reflowingText) {
        root.cursorActive = true
        root.focusSection = "monitors"
        root.selectedIndex = monitorRow.rowIndex
      }
    }
  }

  // A scaled floor-plan of the enabled displays: proportional size (physical
  // pixels / scale, so a 4K@2x monitor doesn't dwarf a 1080p@1x one) and
  // orientation (90°/270° swap the box's aspect ratio), laid out left to
  // right exactly like the Arrangement rows below order them. Purely a
  // read-out — dragging isn't supported, matching the rows' own left/right
  // ordering model.
  // A draggable floor-plan of the enabled displays: proportional size
  // (physical pixels / scale) and orientation (90°/270° swap the box's
  // aspect ratio) like the old static version, but now framed around their
  // real bounding box (free x/y, not a left-to-right sum) and each box can
  // be dragged to a new position — committed via the same applyMonitor/
  // hyprctl-eval path as rotation and refresh rate. Edges and centers snap
  // to nearby boxes within a small threshold so flush layouts don't need
  // pixel-perfect dragging.
  component ArrangementDiagram: Item {
    id: diagram
    // Raised from 170: more absolute working room makes the boxes bigger
    // and easier to grab/aim precisely, on top of the wall-blocking removal
    // that already made crossing between sides possible at all.
    height: Style.space(230)

    readonly property var boxes: {
      var infos = root.enabledMonitorInfos
      var out = []
      for (var i = 0; i < infos.length; i++) {
        var info = infos[i]
        var f = root.monitorFootprint(info)
        out.push({ name: info.name, label: root.friendlyDisplayName(info), x: info.x, y: info.y, w: f.w, h: f.h, focused: info.focused })
      }
      return out
    }

    readonly property real minX: {
      if (boxes.length === 0) return 0
      var m = boxes[0].x
      for (var i = 1; i < boxes.length; i++) if (boxes[i].x < m) m = boxes[i].x
      return m
    }
    readonly property real minY: {
      if (boxes.length === 0) return 0
      var m = boxes[0].y
      for (var i = 1; i < boxes.length; i++) if (boxes[i].y < m) m = boxes[i].y
      return m
    }
    readonly property real maxX: {
      if (boxes.length === 0) return 1
      var m = boxes[0].x + boxes[0].w
      for (var i = 1; i < boxes.length; i++) if (boxes[i].x + boxes[i].w > m) m = boxes[i].x + boxes[i].w
      return m
    }
    readonly property real maxY: {
      if (boxes.length === 0) return 1
      var m = boxes[0].y + boxes[0].h
      for (var i = 1; i < boxes.length; i++) if (boxes[i].y + boxes[i].h > m) m = boxes[i].y + boxes[i].h
      return m
    }
    readonly property real spanX: Math.max(1, maxX - minX)
    readonly property real spanY: Math.max(1, maxY - minY)
    // 0.97: a little headroom so a box near the fitted bounding box's own
    // edge isn't rendered flush against the canvas frame — kept slight
    // since dragging no longer needs to route around other boxes (see
    // onPositionChanged/onReleased below).
    readonly property real pxPerUnit: Math.min(diagram.width / diagram.spanX, diagram.height / diagram.spanY) * 0.97
    readonly property real contentWidth: spanX * pxPerUnit
    readonly property real contentHeight: spanY * pxPerUnit

    // Logical (Hyprland-coordinate) rects of every box except the one being
    // dragged — the snap/collision targets for whichever box is moving.
    // boxes[].x/y are already info.x/info.y verbatim (see `boxes` above),
    // so this needs no screen-space conversion at all.
    function otherLogicalRects(excludeName) {
      var out = []
      for (var i = 0; i < boxes.length; i++) {
        if (boxes[i].name === excludeName) continue
        out.push({ x: boxes[i].x, y: boxes[i].y, w: boxes[i].w, h: boxes[i].h })
      }
      return out
    }

    // logicalX/Y are already the final, snapped, integer position — no
    // conversion happens here, so nothing can drift from what was decided
    // (and displayed) during the drag.
    function commitDrag(name, logicalX, logicalY) {
      var info = root.monitorInfoByName[name]
      if (!info) return
      if (logicalX === info.x && logicalY === info.y) return
      root.applyMonitor(root.withOverrides(info, { x: logicalX, y: logicalY }))
    }

    Item {
      id: diagramInner
      width: diagram.contentWidth
      height: diagram.contentHeight
      anchors.centerIn: parent

      Repeater {
        model: diagram.boxes

        ArrangementBox {
          required property var modelData
          canvas: diagram
          info: modelData
        }
      }
    }
  }

  // One draggable box in the ArrangementDiagram canvas. Position is
  // base (from the model) plus an in-flight drag offset, rather than a
  // direct binding to screen coordinates — dragging never overwrites the
  // model-derived base, so there's nothing to re-bind once the drag ends
  // and the real position (read back from hyprctl) flows into `info`.
  component ArrangementBox: Rectangle {
    id: box
    required property var info
    property Item canvas

    readonly property real baseX: (info.x - canvas.minX) * canvas.pxPerUnit
    readonly property real baseY: (info.y - canvas.minY) * canvas.pxPerUnit
    property real dragDeltaX: 0
    property real dragDeltaY: 0

    x: baseX + dragDeltaX
    y: baseY + dragDeltaY
    width: Math.max(2, info.w * canvas.pxPerUnit - 2)
    height: Math.max(2, info.h * canvas.pxPerUnit - 2)
    radius: Style.cornerRadius
    color: info.focused
      ? Style.selectedFillFor(root.bar.foreground, Color.accent)
      : Style.hoverFillFor(root.bar.foreground, Color.accent)
    border.width: dragArea.dragging ? 2 : 1
    border.color: dragArea.dragging ? Color.accent : root.bar.foreground
    z: dragArea.dragging ? 10 : 1

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: box.info.label
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      width: parent.width - Style.space(8)
      horizontalAlignment: Text.AlignHCenter
    }

    MouseArea {
      id: dragArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.SizeAllCursor

      property bool dragging: false
      property real startCanvasX: 0
      property real startCanvasY: 0
      property real startLogicalX: 0
      property real startLogicalY: 0
      // The authoritative in-flight position, in Hyprland's own logical
      // coordinates. Snapping and overlap checks happen entirely here —
      // never in screen space — so a snap that lands flush against a
      // neighbor's edge is an exact integer match, not a value that only
      // looks flush at diagram scale and drifts by a pixel once divided
      // back out of pxPerUnit. That drift was exactly why two displays
      // that appeared to snap together were still overlapping underneath.
      property real curLogicalX: 0
      property real curLogicalY: 0

      // Mapped into box.parent (diagramInner), which never moves — mapping
      // into the box itself would compare positions in a frame that shifts
      // by exactly the amount already dragged, corrupting the delta.
      onPressed: function(mouse) {
        var p = mapToItem(box.parent, mouse.x, mouse.y)
        startCanvasX = p.x
        startCanvasY = p.y
        startLogicalX = box.info.x
        startLogicalY = box.info.y
        curLogicalX = startLogicalX
        curLogicalY = startLogicalY
        dragging = true
        root.arrangementDragActive = true
      }

      onPositionChanged: function(mouse) {
        if (!dragging) return
        var unit = box.canvas.pxPerUnit
        var p = mapToItem(box.parent, mouse.x, mouse.y)
        var rawX = startLogicalX + (p.x - startCanvasX) / unit
        var rawY = startLogicalY + (p.y - startCanvasY) / unit

        var snap = Style.space(8) / unit
        var others = box.canvas.otherLogicalRects(box.info.name)
        var w = box.info.w, h = box.info.h
        var bestDX = null, bestDY = null

        for (var i = 0; i < others.length; i++) {
          var o = others[i]
          var candidatesX = [o.x - rawX, (o.x + o.w) - (rawX + w), o.x - (rawX + w), (o.x + o.w) - rawX]
          for (var cx = 0; cx < candidatesX.length; cx++) {
            var dx = candidatesX[cx]
            if (Math.abs(dx) <= snap && (bestDX === null || Math.abs(dx) < Math.abs(bestDX))) bestDX = dx
          }
          var candidatesY = [o.y - rawY, (o.y + o.h) - (rawY + h), o.y - (rawY + h), (o.y + o.h) - rawY]
          for (var cy = 0; cy < candidatesY.length; cy++) {
            var dy = candidatesY[cy]
            if (Math.abs(dy) <= snap && (bestDY === null || Math.abs(dy) < Math.abs(bestDY))) bestDY = dy
          }
        }
        if (bestDX !== null) rawX += bestDX
        if (bestDY !== null) rawY += bestDY

        // Round to whole logical pixels now — Hyprland positions are
        // integers, and this is what makes a snap land exactly flush
        // rather than a hair off. No overlap check here: real display-
        // arrangement UIs (GNOME, Windows) let you drag straight across
        // another display mid-gesture — blocking that made it effectively
        // impossible to swing one display from one side of another to the
        // far side, since there was rarely enough spare canvas room to
        // route all the way around it. Overlap is only resolved once, on
        // drop (onReleased).
        curLogicalX = Math.round(rawX)
        curLogicalY = Math.round(rawY)
        box.dragDeltaX = (curLogicalX - box.info.x) * unit
        box.dragDeltaY = (curLogicalY - box.info.y) * unit
      }

      onReleased: {
        dragging = false
        root.arrangementDragActive = false
        // Nudge clear of any overlap only now, at the drop point, using
        // the same resolver rotation-safety and the self-healing refresh
        // check already rely on — reused rather than reimplemented.
        var others = box.canvas.otherLogicalRects(box.info.name)
        var resolved = Model.resolveMonitorOverlap(
          { x: curLogicalX, y: curLogicalY, w: box.info.w, h: box.info.h }, others)
        box.canvas.commitDrag(box.info.name, resolved.x, resolved.y)
        box.dragDeltaX = 0
        box.dragDeltaY = 0
      }
    }
  }

}
