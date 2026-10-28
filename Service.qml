import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "Model.js" as Model

// Everything that talks to Blip: following its live state, handing it
// transfers through its own launch arguments, stopping them through its core,
// and keeping its windows out of sight unless the user asked for the app.
Item {
  id: root

  property var settings: ({})
  // The bar, for saving the plugin's own settings back to shell.json.
  property var bar: null
  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("state.py").toString().replace(/^file:\/\//, ""))

  property bool installed: true
  // zenity draws the file and folder pickers; Omarchy doesn't ship it.
  property bool hasPicker: true
  property bool running: false
  property bool signedIn: false
  property var devices: []
  property var people: []
  property var received: []
  property var transfers: []
  // Your account, this device and Blip's settings (see state.py account()).
  property var account: ({})
  // Sign-in progress: { status, email, error, needsProfile, suggestedDeviceName }.
  property var registration: ({})
  property string loginError: ""
  readonly property bool loginBusy: loginProcess.running
  // Blip is missing, stopped or signed out: the panel and window show setup instead.
  readonly property bool needsSetup: loaded && (!installed || !running || !signedIn || !!registration.needsProfile)
  // Nothing is known until the helper's first report.
  property bool loaded: false
  property real startedAt: 0
  property string lastError: ""
  property string actionStatus: ""
  // Newest received transfer the user has already looked at; anything newer
  // lights the bar dot. Seeded on the first read so old history stays quiet.
  property real seenTime: -1
  readonly property real newestTime: received.length > 0 ? Number(received[0].time || 0) : 0
  readonly property int unseenCount: {
    if (seenTime < 0) return 0
    var n = 0
    for (var i = 0; i < received.length; i++) if (Number(received[i].time || 0) > seenTime) n++
    return n
  }

  readonly property bool hideWindows: setting("hideBlipWindows", true) !== false
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 5, 2, 600)
  readonly property int historyLimit: intSetting("historyLimit", 10, 5, 200)
  readonly property int recentPeople: intSetting("recentPeople", 5, 0, 20)
  readonly property bool busy: pickProcess.running
  readonly property string ownerToken: String(Date.now()) + String(Math.floor(Math.random() * 1e6))

  // Blip's windows are Compose windows that all report the class MainKt.
  readonly property string windowClass: "MainKt"
  // MainKt is the default for any Compose app, so the title tells Blip's apart:
  // "Blip", or "photo.jpg – Receiving from Sam – Blip" for transfer windows.
  readonly property string windowTitle: "Blip"
  function isBlipTitle(title) {
    var t = String(title || "")
    return t === windowTitle || / [–-] Blip$/.test(t)
  }
  readonly property string specialName: "blip"

  property var _pendingPeer: null
  // Windows Blip opens because the plugin itself just handed it a send stay
  // hidden even if Blip asks to be focused.
  property real quietUntil: 0
  // Blip's own picker (for inviting someone without an account) is on
  // screen on purpose: the address of that one window, brought out alone.
  property bool revealing: false
  property bool awaitingPicker: false
  property string pickerAddress: ""
  // The latest name/email lookup: { query, busy, error, people }.
  property var search: ({ query: "", busy: false, error: "", people: [] })
  property string _wantedQuery: ""
  property var _transfersAtHandoff: []
  // The user asked for Blip's own window (its settings and account).
  property real realUntil: 0

  // Blip was opened from the app search: show the plugin's window instead.
  signal appRequested()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // The helper long-polls Blip's core and prints a line on every change, so
  // a refresh only has to restart it for an immediate fresh line.
  function refresh() {
    watchProcess.running = false
    watchRestart.restart()
  }

  function startWatch() {
    watchProcess.command = ["python3", "-I", helperPath, "watch", String(historyLimit), String(refreshIntervalSec), String(recentPeople)]
    watchProcess.running = true
  }

  function applyState(raw) {
    var parsed = Model.parseState(raw)
    if (!parsed.ok) {
      lastError = parsed.error || "Could not read Blip state"
      return
    }
    loaded = true
    installed = parsed.installed === true
    hasPicker = parsed.hasPicker !== false
    running = parsed.running === true
    signedIn = parsed.signedIn === true
    devices = parsed.devices
    people = parsed.people
    received = parsed.received
    transfers = Array.isArray(parsed.transfers) ? parsed.transfers : []
    account = parsed.account || ({})
    registration = parsed.registration || ({})
    lastError = ""
    if (revealing || awaitingPicker) {
      // The picker turns into a transfer once a recipient is chosen.
      for (var i = 0; i < transfers.length; i++) {
        var t = transfers[i]
        if (_transfersAtHandoff.indexOf(t.id) < 0 && t.status !== "Preparing") {
          endReveal()
          break
        }
      }
    }
    if (seenTime < 0) seenTime = newestTime
  }

  function markSeen() {
    seenTime = newestTime
  }

  // Blip forwards a second launch to the running instance over its UI socket,
  // which opens a transfer window and starts sending at once. With the hide
  // rule on, that window lands in the hidden workspace.
  function send(device, paths) {
    if (!device || !paths || paths.length === 0) return
    var command = ["blip", "--peer=" + device.peer]
    for (var i = 0; i < paths.length; i++) command.push("--file=" + paths[i])
    beQuiet()
    Quickshell.execDetached(command)
    flash("Sending " + Model.pendingTitle(paths) + " to " + device.name)
  }

  function stop(transfer) {
    if (!transfer || !transfer.id) return
    Quickshell.execDetached(["python3", "-I", helperPath, "cancel", String(transfer.id)])
    flash("Stopping " + Model.transferTitle(transfer))
  }

  function answer(transfer, accept) {
    if (!transfer || !transfer.id) return
    Quickshell.execDetached(["python3", "-I", helperPath, accept ? "accept" : "decline", String(transfer.id)])
    flash((accept ? "Accepting " : "Declining ") + Model.transferTitle(transfer))
  }

  // Anyone Blip has not met yet has to be looked up by Blip's server, which
  // only its own "To: Name or email" picker can do. Launching with files and
  // no peer opens exactly that picker, so it is shown for this one send.
  function handoff(paths, query) {
    if (!paths || paths.length === 0) return
    var command = ["blip"]
    for (var i = 0; i < paths.length; i++) command.push("--file=" + paths[i])
    beQuiet()
    Quickshell.execDetached(command)
    if (query && String(query).trim() !== "") {
      Quickshell.clipboardText = String(query).trim()
      flash("Paste " + String(query).trim() + " into Blip's To field")
    }
    if (hideWindows) {
      _transfersAtHandoff = transfers.map(function(t) { return t.id })
      awaitingPicker = true
      pickerAddress = ""
      revealTimeout.restart()
    }
  }

  // Looks a name or email up through Blip's core, like Blip's "To" field.
  // Typing restarts a short pause so only the settled text is searched.
  function lookup(query) {
    var q = String(query || "").trim()
    _wantedQuery = q
    if (q.length < 3) {
      lookupDelay.stop()
      search = { query: q, busy: false, error: "", people: [] }
      return
    }
    if (search.query === q && !search.busy && search.error === "") return
    search = { query: q, busy: true, error: "", people: [] }
    lookupDelay.restart()
  }

  function runLookup() {
    if (lookupProcess.running) {
      lookupProcess.running = false
      lookupDelay.restart()
      return
    }
    lookupProcess.query = _wantedQuery
    lookupProcess.command = ["python3", "-I", helperPath, "lookup", _wantedQuery]
    lookupProcess.running = true
  }

  function pickAndHandoff(query) {
    if (pickProcess.running || !pickerReady()) return
    _pendingPeer = { handoff: true, query: query || "" }
    pickProcess.command = ["zenity", "--file-selection", "--multiple", "--separator=\n",
                           "--title=Send with Blip"]
    pickProcess.running = true
  }

  function pickAndSend(device) {
    if (!device || pickProcess.running || !pickerReady()) return
    _pendingPeer = device
    pickProcess.command = ["zenity", "--file-selection", "--multiple", "--separator=\n",
                           "--title=Send to " + device.name + " with Blip"]
    pickProcess.running = true
  }

  // Received files come from other people. Anything that could run code when
  // opened (launchers, scripts, programs) is shown in its folder instead.
  function openFile(file) {
    if (!file || !file.path) return
    if (Model.isRisky(file.name || file.path)) {
      flash(Model.baseName(file.path) + " could run code, so it is shown in its folder")
      revealFile(file)
      return
    }
    Quickshell.execDetached(["xdg-open", String(file.path)])
  }

  function revealFile(file) {
    if (!file || !file.path) return
    // org.freedesktop.FileManager1 is the standard "show this file" request
    // every file manager answers (Nautilus, Dolphin, Nemo, Thunar, Flea...),
    // so the user's own one opens with the file selected. Without one, the
    // folder opens in whatever handles folders.
    var path = String(file.path)
    Quickshell.execDetached(["sh", "-c",
      "busctl --user call org.freedesktop.FileManager1 /org/freedesktop/FileManager1 "
      + "org.freedesktop.FileManager1 ShowItems ass 1 \"$1\" '' || xdg-open \"$2\"",
      "sh", fileUri(path), path.substring(0, path.lastIndexOf("/")) || "/"])
  }

  // The folder Blip saves received files to (its "Save received files to" setting).
  function openDownloads() {
    var dir = String(account.savePath || "") || (Quickshell.env("HOME") + "/Downloads")
    Quickshell.execDetached(["xdg-open", dir])
  }

  function fileUri(path) {
    var parts = String(path || "").split("/")
    for (var i = 0; i < parts.length; i++) parts[i] = encodeURIComponent(parts[i])
    return "file://" + parts.join("/")
  }

  // Blip comes from the AUR (package blipnet). The install runs in Omarchy's
  // floating terminal so the user sees it and answers the sudo prompt there.
  function installBlip() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                             "echo 'Installing Blip (AUR package blipnet) and zenity...'; "
                             + "omarchy-pkg-add zenity && omarchy-pkg-aur-add blipnet"])
  }

  function installPicker() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                             "echo 'Installing zenity for the file picker...'; omarchy-pkg-add zenity"])
  }

  // The pickers need zenity; without it, offer to install it instead.
  function pickerReady() {
    if (hasPicker) return true
    flash("The file picker needs zenity; installing it")
    installPicker()
    return false
  }

  // Blip's core lives in its app process; --background starts it without a window.
  function startBlip() {
    if (!loaded || !installed || running || Date.now() < startedAt + 15000) return
    startedAt = Date.now()
    Quickshell.execDetached(["uwsm-app", "--", "blip", "--background"])
    flash("Starting Blip")
    refresh()
  }

  function sendLoginCode(email, deviceName) {
    runLogin(["email", String(email).trim(), String(deviceName).trim()], "")
  }

  function signIn(code, deviceName) {
    runLogin(["code", String(deviceName).trim()], String(code))
  }

  function finishProfile(name) {
    runLogin(["profile", String(name).trim()], "")
  }

  function runLogin(args, secret) {
    if (loginProcess.running) return
    loginError = ""
    loginProcess.secret = secret
    loginProcess.command = ["python3", "-I", helperPath, "login"].concat(args)
    loginProcess.running = true
  }

  // One of Blip's own settings, applied through its core.
  function setBlip(key, value) {
    Quickshell.execDetached(["python3", "-I", helperPath, "set", String(key), String(value)])
  }

  // One of the plugin's settings, saved to shell.json like the shell's settings panel does.
  function setPlugin(key, value) {
    var next = {}
    for (var k in settings) next[k] = settings[k]
    next[key] = value
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline("tarax.blip", next)
  }

  function pickSaveFolder() {
    if (!pickerReady()) return
    saveFolderProcess.command = ["zenity", "--file-selection", "--directory",
                                 "--title=Save received files to", "--filename=" + (account.savePath || "") + "/"]
    saveFolderProcess.running = true
  }

  function flash(text) {
    actionStatus = text
    statusTimer.restart()
  }

  function beQuiet() {
    quietUntil = Date.now() + 8000
  }

  function quiet() {
    return Date.now() < quietUntil
  }

  // Window handling runs inside Hyprland's Lua so each step sees the windows
  // as they are right now. Every Blip window has the class MainKt and the
  // title "Blip"; the main window is the one that opens tiled (pickers and
  // transfer windows open floating), and it is tagged the first time it is
  // shown so it can still be told apart once it floats.
  readonly property string luaHelpers: [
    "local B = {}",
    "function B.is_blip(t) return t == 'Blip' or t:match(' %- Blip$') ~= nil or t:match(' \u{2013} Blip$') ~= nil end",
    "function B.tagged(w) for _, t in ipairs(w.tags or {}) do if t:gsub('%*$', '') == 'blip-main' then return true end end return false end",
    "function B.main(addr)",
    "  local found",
    "  for _, w in ipairs(hl.get_windows()) do",
    "    if w.class == '" + windowClass + "' and B.is_blip(w.title or '') then",
    "      if addr then",
    "        if w.address == addr and (B.tagged(w) or not w.floating) then return w end",
    "      elseif B.tagged(w) then return w",
    "      elseif not w.floating and not found then found = w end",
    "    end",
    "  end",
    "  if not addr then return found end",
    "end",
    "function B.close_special()",
    "  local s = hl.get_active_special_workspace()",
    "  if s and s.name == 'special:" + specialName + "' then hl.dispatch(hl.dsp.workspace.toggle_special('" + specialName + "')) end",
    "end",
    "function B.show(w)",
    "  local a = 'address:' .. w.address",
    "  B.close_special()",
    "  hl.dispatch(hl.dsp.window.tag({ tag = '+blip-main', window = a }))",
    "  hl.dispatch(hl.dsp.window.move({ workspace = tostring(hl.get_active_workspace().id), window = a, follow = false }))",
    // Sized and centred like Omarchy's other floating utilities (LocalSend).
    "  if not w.floating then",
    "    hl.dispatch(hl.dsp.window.float({ action = 'enable', window = a }))",
    "    hl.dispatch(hl.dsp.window.resize({ x = 1100, y = 700, window = a }))",
    "  end",
    // Blip paints a see-through background meant for a blurred desktop;
    // drawn opaque it reads as a solid window with the theme's border.
    "  hl.dispatch(hl.dsp.window.set_prop({ prop = 'opaque', value = '1', window = a }))",
    "  hl.dispatch(hl.dsp.window.center({ window = a }))",
    "  hl.dispatch(hl.dsp.focus({ window = a }))",
    "end",
    "function B.hide(w)",
    "  hl.dispatch(hl.dsp.window.move({ workspace = 'special:" + specialName + "', window = 'address:' .. w.address, follow = false }))",
    "end",
    // Bring one Blip window (the invite picker) out on its own, or put it back.
    "function B.reveal(addr)",
    "  local a = 'address:' .. addr",
    "  B.close_special()",
    "  hl.dispatch(hl.dsp.window.move({ workspace = tostring(hl.get_active_workspace().id), window = a, follow = false }))",
    "  hl.dispatch(hl.dsp.window.set_prop({ prop = 'opaque', value = '1', window = a }))",
    "  hl.dispatch(hl.dsp.window.center({ window = a }))",
    "  hl.dispatch(hl.dsp.focus({ window = a }))",
    "end",
    "function B.stash(addr)",
    "  for _, w in ipairs(hl.get_windows()) do",
    "    if w.address == addr then B.hide(w) end",
    "  end",
    "end",
    "function B.toggle()",
    "  local w = B.main()",
    "  if not w then hl.exec_cmd('uwsm-app -- blip') return end",
    "  local ws = w.workspace",
    "  if ws and ws.name ~= 'special:" + specialName + "' and ws.id == hl.get_active_workspace().id then B.hide(w) else B.show(w) end",
    "end",
    // Opening Blip from the app search either focuses its hidden main window
    // or creates a new one. Either way the main window stays hidden and the
    // plugin's own window opens, unless Blip's window was asked for.
    "function B.wanted(m, real)",
    "  if real then B.show(m) else hl.exec_cmd('omarchy-shell tarax.blip app') end",
    "end",
    "function B.activated(quiet, real)",
    "  local a = hl.get_active_window()",
    "  B.close_special()",
    "  if quiet or not a then return end",
    "  local m = B.main(a.address)",
    "  if m then B.wanted(m, real) end",
    "end",
    "function B.opened(addr, real)",
    "  local m = B.main(addr)",
    "  if m then B.wanted(m, real) end",
    "end",
    ""
  ].join("\n")

  function lua(call) {
    Quickshell.execDetached(["hyprctl", "eval", luaHelpers + call])
  }

  function wantsReal() {
    return Date.now() < realUntil
  }

  // Blip's own window, for what only Blip can do (settings, account, plan):
  // shown on the current workspace, or tucked away again. Transfer windows
  // stay hidden either way.
  function showRealApp() {
    if (!hideWindows) {
      Quickshell.execDetached(["uwsm-app", "--", "blip"])
      return
    }
    revealing = false
    quietUntil = 0
    realUntil = Date.now() + 8000
    lua("B.toggle()")
  }

  function endReveal() {
    var address = pickerAddress
    revealing = false
    awaitingPicker = false
    pickerAddress = ""
    revealTimeout.stop()
    if (/^0x[0-9a-f]+$/i.test(address)) lua("B.stash('" + address + "')")
  }

  // The rule lives in Hyprland's Lua state, so it is created once, then only
  // switched on and off. A config reload drops that state, which is why the
  // rule is re-applied on every reload event and on each refresh.
  // The owner token stops a shell restart from switching the rule off: the
  // old instance is torn down after the new one has claimed the rule.
  function applyHideRule(forceNew) {
    var lua = forceNew ? "_G.tarax_blip_rule = nil; " : ""
    lua += "_G.tarax_blip_owner = \"" + ownerToken + "\"; "
         + "_G.tarax_blip_rule = _G.tarax_blip_rule or hl.window_rule({ name = \"tarax-blip-hide\", "
         + "match = { class = \"^" + windowClass + "$\", title = \"(^| . )Blip$\" }, "
         + "workspace = \"special:" + specialName + " silent\", no_initial_focus = true }); "
         + "_G.tarax_blip_rule:set_enabled(" + (hideWindows ? "true" : "false") + "); "
         // The plugin's own window floats like Omarchy's other utilities.
         + (forceNew ? "_G.tarax_blip_app_rule = nil; " : "")
         + "_G.tarax_blip_app_rule = _G.tarax_blip_app_rule or hl.window_rule({ name = \"tarax-blip-app\", "
         + "match = { class = \"^org\\\\.quickshell$\", title = \"^Blip$\" }, "
         + "float = true, center = true, size = { 960, 640 } }); "
         + "_G.tarax_blip_app_rule:set_enabled(true)"
    ruleProcess.command = ["hyprctl", "eval", lua]
    if (!ruleProcess.running) ruleProcess.running = true
  }

  function releaseHideRule() {
    Quickshell.execDetached(["hyprctl", "eval",
      "if _G.tarax_blip_rule and _G.tarax_blip_owner == \"" + ownerToken + "\" then _G.tarax_blip_rule:set_enabled(false); "
      + "if _G.tarax_blip_app_rule then _G.tarax_blip_app_rule:set_enabled(false) end end"])
  }

  onHideWindowsChanged: applyHideRule(false)
  onHistoryLimitChanged: refresh()
  onRefreshIntervalSecChanged: refresh()
  onRecentPeopleChanged: refresh()
  Component.onCompleted: {
    applyHideRule(false)
    startWatch()
  }
  Component.onDestruction: releaseHideRule()

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event.name
      var data = String(event.data || "")
      if (name === "configreloaded") {
        root.applyHideRule(true)
      } else if (!root.hideWindows) {
        return
      } else if (name === "activespecial") {
        if (data.indexOf("special:" + root.specialName + ",") !== 0) {
          root.revealing = false
        } else if (!root.revealing) {
          root.lua("B.activated(" + root.quiet() + ", " + root.wantsReal() + ")")
        }
      } else if (name === "openwindow") {
        var parts = data.split(",")
        // Addresses go into Lua, so only plain hex is accepted.
        if (parts.length < 4 || parts[2] !== root.windowClass || !/^[0-9a-f]+$/i.test(parts[0])) return
        if (!root.isBlipTitle(parts.slice(3).join(","))) return
        if (root.awaitingPicker) {
          // The picker Blip opened for the invite: show just that window.
          root.awaitingPicker = false
          root.revealing = true
          root.pickerAddress = "0x" + parts[0]
          root.lua("B.reveal('" + root.pickerAddress + "')")
        } else if (!root.quiet() && !root.revealing) {
          root.lua("B.opened('0x" + parts[0] + "', " + root.wantsReal() + ")")
        }
      } else if (name === "closewindow" && root.revealing && /^[0-9a-f]+$/i.test(data) && "0x" + data === root.pickerAddress) {
        root.revealing = false
        root.pickerAddress = ""
        revealTimeout.stop()
      }
    }
  }

  Timer {
    id: watchRestart
    interval: 2000
    onTriggered: if (!watchProcess.running) root.startWatch()
  }

  Timer {
    id: statusTimer
    interval: 3500
    onTriggered: root.actionStatus = ""
  }

  Timer {
    id: lookupDelay
    interval: 350
    onTriggered: root.runLookup()
  }

  Process {
    id: lookupProcess
    property string query: ""
    command: []
    stdout: StdioCollector { id: lookupStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (lookupProcess.query !== root._wantedQuery) return
      var result = null
      try { result = JSON.parse(String(lookupStdout.text || "")) } catch (e) {}
      if (!result) result = { ok: false, error: "Could not search Blip", people: [] }
      root.search = { query: lookupProcess.query, busy: false, error: result.ok ? "" : String(result.error || ""),
                      people: Array.isArray(result.people) ? result.people : [] }
    }
  }

  // The invite picker goes back into hiding once the transfer starts, or
  // after two minutes.
  Timer {
    id: revealTimeout
    interval: 120000
    onTriggered: if (root.revealing || root.awaitingPicker) root.endReveal()
  }

  Process {
    id: ruleProcess
    command: []
  }

  Process {
    id: watchProcess
    command: []
    stdout: SplitParser {
      onRead: function(line) { root.applyState(line) }
    }
    onExited: watchRestart.restart()
  }

  Process {
    id: pickProcess
    command: []
    stdout: StdioCollector { id: pickStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var device = root._pendingPeer
      root._pendingPeer = null
      if (exitCode !== 0) return
      var paths = String(pickStdout.text || "").split("\n").filter(function(p) { return p.trim() !== "" })
      if (device && device.handoff) root.handoff(paths, device.query)
      else root.send(device, paths)
    }
  }

  Process {
    id: saveFolderProcess
    command: []
    stdout: StdioCollector { id: saveFolderStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var path = String(saveFolderStdout.text || "").trim()
      if (exitCode === 0 && path !== "") root.setBlip("savePath", path)
    }
  }

  Process {
    id: loginProcess
    property string secret: ""
    command: []
    stdinEnabled: true
    stderr: StdioCollector { id: loginStderr; waitForEnd: true }
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.loginError = String(loginStderr.text || "").trim() || "Could not reach Blip"
      root.refresh()
    }
  }
}
