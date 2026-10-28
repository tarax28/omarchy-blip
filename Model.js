var IMAGE_EXTENSIONS = {
  jpg: true, jpeg: true, png: true, gif: true, webp: true, avif: true, heic: true,
  svg: true, bmp: true, tif: true, tiff: true
}

var VIDEO_EXTENSIONS = {
  mp4: true, mov: true, mkv: true, webm: true, avi: true, m4v: true, mpg: true,
  mpeg: true, wmv: true
}

var DOCUMENT_EXTENSIONS = {
  pdf: true, txt: true, md: true, doc: true, docx: true, xls: true, xlsx: true,
  ppt: true, pptx: true, odt: true, ods: true, odp: true, rtf: true, csv: true
}

// Files that can run code when opened from a file manager or xdg-open.
var RISKY_EXTENSIONS = {
  desktop: true, sh: true, bash: true, zsh: true, fish: true, run: true, bin: true,
  appimage: true, flatpakref: true, jar: true, py: true, pl: true, rb: true, exe: true,
  msi: true, bat: true, cmd: true, ps1: true, vbs: true, deb: true, rpm: true, apk: true
}

function isRisky(name) {
  var value = String(name || "").toLowerCase()
  if (/\.pkg\.tar\.(zst|xz|gz)$/.test(value)) return true
  return RISKY_EXTENSIONS[fileExtension(value)] === true
}

function parseState(raw) {
  var text = String(raw || "").trim()
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return defaultState()
    parsed.devices = Array.isArray(parsed.devices) ? parsed.devices : []
    parsed.people = Array.isArray(parsed.people) ? parsed.people : []
    parsed.received = Array.isArray(parsed.received) ? parsed.received : []
    parsed.transfers = Array.isArray(parsed.transfers) ? parsed.transfers : []
    parsed.registration = parsed.registration || {}
    return parsed
  } catch (e) {
    var failed = defaultState()
    failed.ok = false
    failed.error = "Failed to parse Blip state"
    return failed
  }
}

function defaultState() {
  return { ok: true, installed: false, running: false, signedIn: false, devices: [], people: [], transfers: [], received: [] }
}

// Blip only reports a numeric platform, and phones and tablets share one, so
// the name breaks the tie.
function deviceGlyph(device) {
  var name = String(device && device.name || "").toLowerCase()
  if (/tab|ipad|pad\b/.test(name)) return "󰓶"
  if (/phone|pixel|galaxy s|android|mobile/.test(name)) return "󰄜"
  var kind = Number(device && device.kind || 0)
  if (kind === 1 || kind === 2) return "󰄜"
  if (/desktop|pc\b|tower/.test(name)) return "󰍹"
  return "󰌢"
}

function deviceMeta(device, nowMs) {
  if (!device) return ""
  var parts = []
  if (!device.mine && device.owner) parts.push(device.owner)
  parts.push(device.lastSeen > 0 ? "Seen " + relativeTime(device.lastSeen, nowMs).toLowerCase() : "Not seen yet")
  return parts.join(" · ")
}

function fileExtension(name) {
  var value = String(name || "").toLowerCase()
  var index = value.lastIndexOf(".")
  return index >= 0 ? value.substring(index + 1) : ""
}

function fileGlyph(name) {
  var ext = fileExtension(name)
  if (IMAGE_EXTENSIONS[ext]) return "󰋩"
  if (VIDEO_EXTENSIONS[ext]) return "󰈫"
  if (DOCUMENT_EXTENSIONS[ext]) return "󰈙"
  return "󰈔"
}

function formatBytes(bytes) {
  var value = Number(bytes || 0)
  if (!isFinite(value) || value <= 0) return ""
  var units = ["B", "KB", "MB", "GB", "TB"]
  var index = 0
  while (value >= 1000 && index < units.length - 1) {
    value = value / 1000
    index++
  }
  var decimals = value >= 100 || index === 0 ? 0 : (value >= 10 ? 1 : 2)
  return value.toFixed(decimals).replace(/\.0+$/, "").replace(/(\.\d)0$/, "$1") + " " + units[index]
}

function relativeTime(timestampSec, nowMs) {
  var ts = Number(timestampSec || 0)
  if (!isFinite(ts) || ts <= 0) return "Unknown time"
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  var diff = Math.max(0, Math.floor((now - ts * 1000) / 1000))
  if (diff < 60) return "Just now"
  var minutes = Math.floor(diff / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  if (days < 30) return days + "d ago"
  var months = Math.floor(days / 30)
  if (months < 12) return months + "mo ago"
  return Math.floor(days / 365) + "y ago"
}

function fileMeta(file, nowMs) {
  if (!file) return ""
  var parts = [relativeTime(file.time, nowMs), "from " + (file.from || "Unknown")]
  var size = formatBytes(file.size)
  if (size !== "") parts.push(size)
  if (file.exists === false) parts.push("moved or deleted")
  return parts.join(" · ")
}

function transferTitle(transfer) {
  var names = transfer && transfer.names || []
  if (names.length === 0) return "Files"
  if (names.length === 1) return names[0]
  return names[0] + " + " + (names.length - 1) + " more"
}

function transferFraction(transfer) {
  var total = Number(transfer && transfer.total || 0)
  if (total <= 0) return 0
  return Math.max(0, Math.min(1, Number(transfer.done || 0) / total))
}

// Blip reports speed in kilobits per second.
function formatSpeed(kbps) {
  var bytes = Number(kbps || 0) * 125
  return bytes > 0 ? formatBytes(bytes) + "/s" : ""
}

function transferMeta(transfer) {
  if (!transfer) return ""
  var parts = [(transfer.outgoing ? "To " : "From ") + (transfer.peer || "Unknown")]
  var total = Number(transfer.total || 0)
  if (transfer.asking) {
    parts.push("Wants to send you this")
    if (total > 0) parts.push(formatBytes(total))
    return parts.join(" · ")
  }
  if (transfer.status === "Active" && total > 0) {
    parts.push((formatBytes(transfer.done) || "0 B") + " of " + formatBytes(total))
    var speed = formatSpeed(transfer.kbps)
    if (speed !== "") parts.push(speed)
  } else {
    parts.push(transfer.status || "Waiting")
    if (total > 0) parts.push(formatBytes(total))
  }
  return parts.join(" · ")
}

function pathsFromUris(raw) {
  var out = []
  var lines = String(raw || "").split(/\r?\n/)
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "" || line.charAt(0) === "#") continue
    if (line.indexOf("file://") !== 0) continue
    var path = line.substring(7)
    // file://host/path: only the local host is a path we can hand to Blip.
    if (path.charAt(0) !== "/") {
      var slash = path.indexOf("/")
      if (slash < 0) continue
      path = path.substring(slash)
    }
    try { path = decodeURIComponent(path) } catch (e) {}
    out.push(path)
  }
  return out
}

function baseName(path) {
  var value = String(path || "")
  var slash = value.lastIndexOf("/")
  return slash >= 0 ? value.substring(slash + 1) : value
}

function pendingTitle(paths) {
  if (!paths || paths.length === 0) return ""
  if (paths.length === 1) return baseName(paths[0])
  return paths.length + " files"
}

function matches(query, fields) {
  var q = String(query || "").trim().toLowerCase()
  if (q === "") return true
  for (var i = 0; i < fields.length; i++) {
    if (String(fields[i] || "").toLowerCase().indexOf(q) >= 0) return true
  }
  return false
}

function looksLikeEmail(text) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(text || "").trim())
}

// One list for the "To" picker, in Blip's own order: your devices, the people
// Blip already knows, then anyone Blip's server found for the typed name or
// email (search is the latest lookup the service ran, for search.query).
function targets(devices, people, query, search) {
  var out = []
  var q = String(query || "").trim()
  var known = {}
  for (var i = 0; i < devices.length; i++) {
    var d = devices[i]
    if (!matches(q, [d.name, d.owner, d.email])) continue
    out.push({ type: "device", peer: d.peer, name: d.name, glyph: deviceGlyph(d), meta: deviceMeta(d), target: d })
  }
  for (var j = 0; j < people.length; j++) {
    var p = people[j]
    known[p.peer] = true
    if (!matches(q, [p.name, p.email])) continue
    pushPerson(out, p)
  }
  var current = search && search.query === q
  if (q !== "" && current) {
    var found = search.people || []
    for (var k = 0; k < found.length; k++) {
      if (known[found[k].peer]) continue
      pushPerson(out, found[k])
    }
  }
  if (q === "") {
    out.push({ type: "focus", name: "Send to other people", glyph: "󰀉",
               meta: "Type a name or email to find anyone on Blip" })
  } else if (out.length === 0) {
    if (!current || search.busy) {
      out.push({ type: "status", name: "Searching Blip for " + q + "…", glyph: "󰍉", meta: "Looking up names and emails" })
    } else if (search.error) {
      out.push({ type: "status", name: search.error, glyph: "󰀦", meta: "Check that Blip is running and online" })
    } else if (looksLikeEmail(q)) {
      out.push({ type: "handoff", name: "Invite " + q, glyph: "󰇮",
                 meta: "No Blip account yet · Blip sends them an invite", query: q })
    } else {
      out.push({ type: "status", name: "No one found for " + q, glyph: "󰀉", meta: "Try their full email address" })
    }
  }
  return out
}

// A person sends to all their devices; with more than one, each device is
// listed under them so a send can go to just one.
function pushPerson(out, p) {
  out.push(personEntry(p))
  var list = Array.isArray(p.deviceList) ? p.deviceList : []
  if (list.length < 2) return
  for (var i = 0; i < list.length; i++) {
    var d = list[i]
    out.push({ type: "device", nested: true, peer: d.peer, name: d.name, glyph: deviceGlyph(d),
               meta: deviceMeta({ lastSeen: d.lastSeen, mine: true }),
               target: { peer: d.peer, name: (p.name || p.email) + "'s " + d.name } })
  }
}

function personEntry(p) {
  var count = Number(p.devices || 0)
  var meta = [p.email]
  if (count > 1) meta.push("all " + count + " devices")
  else if (count === 1) meta.push("1 device")
  return { type: "person", peer: p.peer, name: p.name || p.email, glyph: "󰀄",
           meta: meta.filter(function(x) { return x }).join(" · "), target: p }
}
