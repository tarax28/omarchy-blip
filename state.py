#!/usr/bin/env python3
"""Read Blip's state and print devices, transfers and received files as JSON.

While Blip runs, its core serves the live state over DRPC on a unix socket
(rpc.Service/GetState, which long-polls until the state changes) and takes
events through rpc.Service/Dispatch. When it is not running, the same state
is read from ~/.local/share/net.blip.Blip/state.dat. Field numbers come from
Blip's own protobuf descriptors; this decoder only walks the wire format and
picks out the fields it knows, so anything unexpected is skipped, never fatal.

  state.py [limit]                   print one snapshot
  state.py watch [limit] [interval] [people]  print a JSON line whenever the state changes
  state.py set <setting> <value>     change one of Blip's settings
  state.py login email <email> <device name>   ask Blip to email a sign-in code
  state.py login code <device name>            sign in with the code read from stdin
  state.py login profile <name>                finish sign-up with your name
  state.py cancel <transfer id>      stop a transfer
  state.py lookup <name or email>    find Blip users the way Blip's "To" picker does
"""
import json
import os
import socket
import struct
import subprocess
import sys
import shutil
import time
import uuid
from pathlib import Path

STATE = Path.home() / ".local/share/net.blip.Blip/state.dat"
SOCKET = Path.home() / ".cache/net.blip.Blip/sock"

# frontend.Transfer.Status values that still need the user's attention.
RECENT_PEOPLE = 5
LIVE_STATUS = {1: "Preparing", 2: "Inviting", 3: "Waiting", 4: "Waiting", 5: "Active",
               6: "Paused", 7: "Resuming"}


def varint(buf, i):
  result = shift = 0
  while True:
    byte = buf[i]
    i += 1
    result |= (byte & 0x7F) << shift
    shift += 7
    if byte < 0x80:
      return result, i


def fields(buf):
  """Yield (field, value) pairs; length-delimited values stay as bytes."""
  i = 0
  while i < len(buf):
    key, i = varint(buf, i)
    field, wire = key >> 3, key & 7
    if wire == 0:
      value, i = varint(buf, i)
    elif wire == 1:
      value, i = buf[i:i + 8], i + 8
    elif wire == 5:
      value, i = buf[i:i + 4], i + 4
    elif wire == 2:
      length, i = varint(buf, i)
      value, i = buf[i:i + length], i + length
    else:
      raise ValueError("unsupported wire type")
    yield field, value


def first(buf, field, default=None):
  for f, v in fields(buf):
    if f == field:
      return v
  return default


def all_of(buf, field):
  return [v for f, v in fields(buf) if f == field]


def text(value):
  return value.decode("utf-8", "replace").strip() if isinstance(value, bytes) else ""


def seconds(stamp):
  if not isinstance(stamp, bytes):
    return 0
  value = first(stamp, 1, 0)
  # Never-seen devices carry a negative int64, which arrives here as a huge varint.
  return value if isinstance(value, int) and 0 < value < 1 << 40 else 0


def uvarint(n):
  out = bytearray()
  while True:
    byte, n = n & 0x7F, n >> 7
    out.append(byte | (0x80 if n else 0))
    if not n:
      return bytes(out)


def delimited(field, payload):
  return uvarint(field << 3 | 2) + uvarint(len(payload)) + payload


def recv_exact(sock, size):
  data = b""
  while len(data) < size:
    chunk = sock.recv(size - len(data))
    if not chunk:
      raise EOFError("Blip closed the connection")
    data += chunk
  return data


def recv_varint(sock):
  result = shift = 0
  while True:
    byte = recv_exact(sock, 1)[0]
    result |= (byte & 0x7F) << shift
    shift += 7
    if byte < 0x80:
      return result


def rpc(method, request, timeout=5):
  """One unary DRPC call: invoke, message, close-send; returns the reply bytes."""
  def frame(kind, message_id, data):
    return bytes([kind << 1 | 1]) + uvarint(1) + uvarint(message_id) + uvarint(len(data)) + data

  with socket.socket(socket.AF_UNIX) as sock:
    sock.settimeout(timeout)
    sock.connect(str(SOCKET))
    sock.sendall(frame(1, 1, method.encode()) + frame(2, 2, request) + frame(6, 3, b""))
    reply = b""
    while True:
      control = recv_exact(sock, 1)[0]
      recv_varint(sock)
      recv_varint(sock)
      data = recv_exact(sock, recv_varint(sock))
      kind, done = control >> 1 & 0x3F, control & 1
      if kind == 2:
        reply += data
        if done:
          return reply
      elif kind == 3:
        raise RuntimeError(data[8:].decode("utf-8", "replace") or "Blip refused the request")
      elif kind == 5:
        return reply


def dispatch(name, message):
  # Dispatch takes the event as a google.protobuf.Any.
  event = delimited(1, ("type.googleapis.com/event." + name).encode()) + delimited(2, message)
  rpc("/rpc.Service/Dispatch", delimited(1, event))


def stop(transfer_id):
  # Blip only cancels a transfer once it has been offered; a draft that is
  # still being prepared is removed instead (its source files are kept).
  state = first(rpc("/rpc.Service/GetState", b""), 2, b"")
  status = 0
  for f, v in fields(state):
    if f == 600 and text(first(first(v, 2, b""), 100, b"")) == transfer_id:
      status = first(first(v, 2, b""), 800, 0)
  key = delimited(1, transfer_id.encode())
  if status == 1:
    dispatch("TransferRemoveRequested", key)
  else:
    dispatch("TransferCancellationRequested", key)


def save_dir(state):
  return text(first(first(state, 100, b""), 4, b"")) or str(Path.home() / "Downloads")


def answer(transfer_id, accept):
  key = delimited(1, transfer_id.encode())
  if accept:
    # Where Blip's own settings say received files go.
    state = first(rpc("/rpc.Service/GetState", b""), 2, b"")
    dispatch("TransferAcceptanceRequested", key + delimited(2, save_dir(state).encode()))
  else:
    dispatch("TransferDeclineRequested", key)


def varint_field(field, value):
  return uvarint(field << 3) + uvarint(value)


def change(key, value):
  """Apply one setting the way Blip's own settings screen does."""
  state = first(rpc("/rpc.Service/GetState", b""), 2, b"")
  auth = first(state, 201, b"")
  flag = 1 if value in ("1", "true", "on") else 0
  if key == "name":
    dispatch("UpdateUser", delimited(1, value.encode()))
  elif key == "searchable":
    dispatch("UpdateUser", varint_field(2, flag))
  elif key == "deviceName":
    dispatch("UpdateDevice", delimited(1, first(auth, 204, b"")) + delimited(2, value.encode()))
  elif key == "autoAccept":
    dispatch("TransferSetAutoAccept", varint_field(1, flag))
  elif key == "savePath":
    dispatch("TransferSetCustomDefaultSavePath", delimited(1, value.encode()))
  elif key in ("uploadLimit", "downloadLimit"):
    dispatch("TransferSetSpeedLimits", varint_field(1 if key == "uploadLimit" else 2, max(0, int(value))))
  elif key == "diagnostics":
    dispatch("SetAllowConnectionDiagnostics", varint_field(1, flag))
  elif key == "logout":
    dispatch("Logout", b"")
  else:
    raise ValueError("unknown setting: " + key)


def account(buf):
  """Your own account, this device and Blip's settings, for the settings view."""
  auth = first(buf, 201, b"")
  config = first(buf, 100, b"")
  me_user = text(first(auth, 202, b""))
  me_device = text(first(auth, 204, b""))
  out = {"email": text(first(auth, 203, b"")), "name": "", "searchable": False,
         "deviceName": "", "devices": [], "diagnostics": False,
         "autoAccept": not first(config, 2, 0), "savePath": save_dir(buf),
         "uploadLimit": first(config, 5, 0), "downloadLimit": first(config, 6, 0)}
  for f, v in fields(buf):
    if f != 500:
      continue
    for contact in all_of(v, 1):
      if text(first(contact, 1, b"")) != me_user:
        continue
      info = first(contact, 2, b"")
      out["name"] = text(first(info, 2, b""))
      out["searchable"] = bool(first(info, 11, 0))
      for entry in all_of(info, 7):
        device = first(entry, 2, b"")
        device_id = text(first(device, 1, b""))
        name = text(first(device, 3, b"")).strip() or "Device"
        if device_id == me_device:
          out["deviceName"] = name
          out["diagnostics"] = bool(first(first(device, 1000, b""), 1, 0))
        out["devices"].append({"name": name, "current": device_id == me_device,
                               "kind": first(device, 2, 0), "lastSeen": seconds(first(device, 5))})
  return out


# Blip's frontend.Onboarding.Step.Kind and DeviceKind values.
STEP_PROFILE = 3
REGISTRATION_STATUS = {0: "idle", 1: "sending", 2: "codeSent", 3: "registering"}


def device_kind():
  # SMBIOS chassis types for portables, as Blip's own desktop app maps them.
  try:
    chassis = int(Path("/sys/class/dmi/id/chassis_type").read_text().strip())
  except (OSError, ValueError):
    return 5
  return 4 if chassis in (8, 9, 10, 11, 14, 30, 31, 32) else 5


def dedupe_id():
  """The id Blip keeps so a reinstall replaces this device instead of adding one."""
  path = Path.home() / ".local/share/net.blip.Blip/hardwareinfo/device-dedupe-id.txt"
  try:
    first_line = path.read_text().splitlines()[0].strip()
    if first_line:
      return first_line
  except (OSError, IndexError):
    pass
  value = str(uuid.uuid4())
  path.parent.mkdir(parents=True, exist_ok=True)
  path.write_text(value + "\nThis file is used to clean up old devices in Blip when reinstalling. "
                  "You can delete it if you like.\n")
  return value


def login(step, args):
  if step == "email":
    # The splash is the first onboarding step; Blip's own window skips it the same way.
    dispatch("OnboardingSkipSplash", b"")
    dispatch("SendRegistrationCodeRequested",
             delimited(1, args[0].strip().encode()) + delimited(2, " ".join(args[1:]).strip().encode()))
  elif step == "code":
    # Read from stdin so the one-time code never shows up in the process list.
    code = "".join(sys.stdin.readline().split())
    if not code:
      raise ValueError("no code given")
    dispatch("RegistrationRequested",
             delimited(1, code.encode()) + delimited(2, dedupe_id().encode())
             + delimited(3, " ".join(args).strip().encode()) + varint_field(4, device_kind()))
  elif step == "profile":
    name = " ".join(args).strip()
    if name:
      dispatch("UpdateUser", delimited(1, name.encode()))
    for skip in ("OnboardingSkipCompanionDeviceSetup", "OnboardingSkipEnableNotifications",
                 "OnboardingSkipEnableMediaLibrary", "OnboardingSkipShareInstructions"):
      dispatch(skip, b"")
  else:
    raise ValueError("unknown login step: " + step)


def registration(buf):
  """Where sign-in stands, for the plugin's login page."""
  reg = first(buf, 200, b"")
  error = first(reg, 999, b"") if reg else b""
  step = first(first(first(buf, 300, b""), 1, b""), 1, 0)
  return {"status": REGISTRATION_STATUS.get(first(reg, 1, 0) if reg else 0, "idle"),
          "email": text(first(reg, 4, b"")) if reg else "",
          "error": text(first(error, 2, b"")) if error else "",
          "needsProfile": step == STEP_PROFILE,
          "suggestedDeviceName": suggested_device_name()}


def suggested_device_name():
  for source in ("/sys/class/dmi/id/product_name", "/etc/hostname"):
    try:
      name = Path(source).read_text().strip()
    except OSError:
      continue
    if name and name.lower() not in ("system product name", "to be filled by o.e.m.", "default string"):
      return name
  return "Linux PC"


def device_list(user_id, info):
  """Someone's devices, so a send can go to one of them instead of all."""
  out = []
  for entry in all_of(info, 7):
    device = first(entry, 2, b"")
    device_id = text(first(device, 1, b""))
    if not device_id:
      continue
    out.append({"peer": user_id + ":" + device_id,
                "name": text(first(device, 3, b"")).strip() or "Device",
                "kind": first(device, 2, 0),
                "lastSeen": seconds(first(device, 5))})
  return out


def users(state):
  """user id -> (name, email, devices) for every user the state knows about."""
  known = {}
  for f, v in fields(state):
    if f == 500:
      for contact in all_of(v, 1):
        user_id = text(first(contact, 1, b""))
        info = first(contact, 2, b"")
        email = text(first(info, 1, b""))
        known[user_id] = (text(first(info, 2, b"")) or email, email, device_list(user_id, info))
  return known


def lookup(query, timeout=10):
  """Run a search through Blip's core and return the people it found."""
  search_id = "tarax-" + str(time.time_ns())
  dispatch("Search", delimited(1, search_id.encode()) + delimited(2, query.encode()))
  deadline = time.time() + timeout
  try:
    while time.time() < deadline:
      time.sleep(0.3)
      state = first(rpc("/rpc.Service/GetState", b""), 2, b"")
      me = text(first(first(state, 201, b""), 202, b""))
      for f, v in fields(state):
        if f != 800 or text(first(v, 1, b"")) != search_id:
          continue
        search = first(v, 2, b"")
        status = first(search, 2, 0)
        if status == 2:
          return {"ok": False, "error": "Blip could not search right now", "people": []}
        if status != 3:
          continue
        known = users(state)
        people, seen = [], set()
        for peer in all_of(search, 3) + all_of(search, 4):
          user = text(first(peer, 1, b""))
          if not user or user in seen or user == me:
            continue
          seen.add(user)
          name, email, devices = known.get(user, ("", "", []))
          people.append({"peer": user + ":", "name": name or email or query,
                         "email": email or (query if "@" in query else ""),
                         "devices": len(devices), "deviceList": devices})
        return {"ok": True, "people": people}
    return {"ok": False, "error": "Blip did not answer in time", "people": []}
  finally:
    try:
      dispatch("AbandonSearch", delimited(1, search_id.encode()))
    except (OSError, EOFError, RuntimeError):
      pass


def running():
  try:
    return subprocess.run(["pgrep", "-x", "blip"], capture_output=True, timeout=2).returncode == 0
  except (OSError, subprocess.SubprocessError):
    return False


def parse(buf):
  me_user = me_device = ""
  for f, v in fields(buf):
    if f == 201:
      me_user = text(first(v, 202, b""))
      me_device = text(first(v, 204, b""))

  devices = []
  people = {}
  contacts = []
  transfers = []
  download_dir = str(Path.home() / "Downloads")

  for f, v in fields(buf):
    if f == 500:
      for contact in all_of(v, 1):
        user_id = text(first(contact, 1, b""))
        info = first(contact, 2, b"")
        email = text(first(info, 1, b""))
        owner = text(first(info, 2, b"")) or email
        people[user_id] = owner
        if user_id and user_id != me_user:
          # An empty device id addresses the person, so Blip delivers to all their devices.
          contacts.append({"peer": user_id + ":", "name": owner or "Someone", "email": email,
                           "devices": len(all_of(info, 7)), "deviceList": device_list(user_id, info)})
        # Search results land in the same list; keep their devices out of the picker.
        for entry in all_of(info, 7):
          device = first(entry, 2, b"")
          device_id = text(first(device, 1, b""))
          if not device_id or device_id == me_device or first(device, 6, 0) == 1:
            continue
          devices.append({
            "peer": user_id + ":" + device_id,
            "name": text(first(device, 3, b"")) or "Device",
            "owner": owner,
            "email": email,
            "mine": user_id == me_user,
            "kind": first(device, 2, 0),
            "lastSeen": seconds(first(device, 5)),
          })
    elif f == 600:
      transfer = first(v, 2, b"")
      if transfer:
        transfers.append(transfer)

  # Only people you have sent to, most recent first; everyone else is a search away.
  sent = {}
  for transfer in transfers:
    if first(transfer, 700, 0) != 2:
      continue
    user = text(first(first(transfer, 200, b""), 1, b""))
    when = seconds(first(transfer, 1300))
    if user and user != me_user and when >= sent.get(user, -1):
      sent[user] = when
  contacts = sorted((c for c in contacts if c["peer"][:-1] in sent),
                    key=lambda c: sent[c["peer"][:-1]], reverse=True)[:RECENT_PEOPLE]
  # Other people's devices are listed under each person instead.
  devices = [d for d in devices if d["mine"]]

  def peer_name(peer):
    user = text(first(peer, 1, b""))
    device = text(first(peer, 2, b""))
    named = next((d["name"] for d in devices if d["peer"] == user + ":" + device), "")
    owner = people.get(user, "")
    if named and owner and user != me_user:
      return owner + " · " + named
    return named or owner or "Unknown"

  live = []
  for transfer in transfers:
    status = first(transfer, 800, 0)
    if status not in LIVE_STATUS or first(transfer, 1000, 0):
      continue
    names, total = [], 0
    for item in all_of(first(transfer, 400, b""), 1):
      names.append(text(first(item, 1, b"")))
      info = first(first(item, 2, b""), 1, b"")
      total += first(info, 1, 0) if info else 0
    stats = first(transfer, 1200, b"")
    kbps = first(stats, 1, b"") if stats else b""
    progress = first(transfer, 1100, 0)
    live.append({
      "id": text(first(transfer, 100, b"")),
      "outgoing": first(transfer, 700, 0) == 2,
      "status": LIVE_STATUS[status],
      "paused": status == 6,
      # Offered to us and waiting on an answer.
      "asking": first(transfer, 700, 0) == 1 and status == 3,
      "peer": peer_name(first(transfer, 200, b"")),
      "names": [n for n in names if n],
      "total": total,
      "done": min(progress, total) if total else progress,
      "kbps": struct.unpack("<d", kbps)[0] if len(kbps) == 8 else 0,
    })

  received = []
  for transfer in transfers:
    if first(transfer, 700, 0) != 1:
      continue
    peer = first(transfer, 200, b"")
    sender_user = text(first(peer, 1, b""))
    sender_device = text(first(peer, 2, b""))
    base = text(first(transfer, 501, b"")) or download_dir
    when = seconds(first(transfer, 1300))
    files = first(transfer, 400, b"")
    sizes = {}
    for meta in all_of(files, 1):
      name = text(first(meta, 1, b""))
      info = first(first(meta, 2, b""), 1, b"")
      sizes[name] = first(info, 1, 0) if info else 0
    for placed in all_of(files, 2):
      name = text(first(placed, 1, b""))
      where = text(first(placed, 2, b""))
      if where.startswith("downloads://"):
        where = os.path.join(base, where[len("downloads://"):])
      elif not where:
        where = os.path.join(base, name)
      device_name = next((d["name"] for d in devices if d["peer"] == sender_user + ":" + sender_device), "")
      received.append({
        "name": name,
        "path": where,
        "size": sizes.get(name, 0),
        "time": when,
        "from": device_name or people.get(sender_user, "") or "Unknown",
        "exists": os.path.exists(where),
      })

  received.sort(key=lambda r: r["time"], reverse=True)
  devices.sort(key=lambda d: (not d["mine"], -d["lastSeen"], d["name"].lower()))
  contacts.sort(key=lambda c: c["name"].lower())
  return devices, contacts, live, received


def report(buf, limit, is_running):
  out = {"ok": True, "installed": shutil.which("blip") is not None, "running": is_running,
         "hasPicker": shutil.which("zenity") is not None,
         "signedIn": False, "devices": [], "people": [], "transfers": [], "received": []}
  if buf is None:
    return out
  try:
    devices, contacts, live, received = parse(buf)
  except (ValueError, IndexError) as err:
    out.update(ok=False, error="Could not read Blip state: " + str(err))
    return out
  signed_in = bool(first(first(buf, 201, b""), 202, b""))
  out.update(signedIn=signed_in, registration=registration(buf))
  if signed_in:
    out.update(devices=devices, people=contacts, transfers=live, received=received[:limit],
               account=account(buf))
  return out


def snapshot(limit):
  try:
    buf = STATE.read_bytes()
  except OSError:
    buf = None
  return report(buf, limit, running())


def emit(out):
  sys.stdout.write(json.dumps(out, separators=(",", ":")) + "\n")
  sys.stdout.flush()


def watch(limit, interval):
  last_id = None
  while True:
    try:
      request = b"" if last_id is None else b"\x08" + uvarint(last_id)
      # GetState holds the call open until something changes.
      reply = rpc("/rpc.Service/GetState", request, timeout=120)
      last_id = first(reply, 1, 0)
      emit(report(first(reply, 2, b""), limit, True))
      # Progress ticks arrive many times a second; a quarter second is plenty.
      time.sleep(0.25)
    except socket.timeout:
      continue
    except (OSError, EOFError, RuntimeError, ValueError, IndexError):
      last_id = None
      emit(snapshot(limit))
      time.sleep(interval)


def main():
  args = sys.argv[1:]
  if args and args[0] == "cancel":
    try:
      stop(args[1])
    except (OSError, EOFError, RuntimeError, IndexError) as err:
      print("Could not stop the transfer: " + str(err), file=sys.stderr)
      sys.exit(1)
    return
  if args and args[0] in ("accept", "decline"):
    try:
      answer(args[1], args[0] == "accept")
    except (OSError, EOFError, RuntimeError, IndexError) as err:
      print("Could not answer the transfer: " + str(err), file=sys.stderr)
      sys.exit(1)
    return
  if args and args[0] == "login":
    try:
      login(args[1], args[2:])
    except (OSError, EOFError, RuntimeError, IndexError, ValueError) as err:
      print("Could not sign in: " + str(err), file=sys.stderr)
      sys.exit(1)
    return
  if args and args[0] == "set":
    try:
      change(args[1], " ".join(args[2:]))
    except (OSError, EOFError, RuntimeError, IndexError, ValueError) as err:
      print("Could not change the setting: " + str(err), file=sys.stderr)
      sys.exit(1)
    return
  if args and args[0] == "lookup":
    try:
      emit(lookup(" ".join(args[1:]).strip()))
    except (OSError, EOFError, RuntimeError, ValueError, IndexError):
      emit({"ok": False, "error": "Blip is not running", "people": []})
    return
  if args and args[0] == "watch":
    limit = int(args[1]) if len(args) > 1 else 30
    interval = max(1, int(args[2])) if len(args) > 2 else 5
    global RECENT_PEOPLE
    RECENT_PEOPLE = max(0, int(args[3])) if len(args) > 3 else RECENT_PEOPLE
    try:
      watch(limit, interval)
    except (BrokenPipeError, KeyboardInterrupt):
      pass
    return
  emit(snapshot(int(args[0]) if args else 30))


if __name__ == "__main__":
  main()
