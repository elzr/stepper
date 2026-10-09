// What Hammerspoon can't read itself about the keyboard, for stepper's key repeat and its
// "[stepper] lost key-up" console line. Built by inputprobe.lua on first use; prints one
// JSON document.
//
//   inputprobe keys <keycode>...          which of these keys the HID system still holds down
//   inputprobe taps                       every event tap that sees key events, and its state
//   inputprobe hold <keycode> [maxSec]    waits until the HID system lets go of the key
//
// See case-studies/2026-10-07-runaway-hotkey-repeat-after-lost-key-up.md
// and case-studies/2026-10-09-lost-key-up-walked-note-down.md

import AppKit
import CoreGraphics

func emit(_ doc: [String: Any]) -> Never {
  let data = (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]))
    ?? Data("{\"ok\":false,\"error\":\"unencodable result\"}".utf8)
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
  exit(doc["ok"] as? Bool == true ? 0 : 1)
}

func processName(_ pid: pid_t) -> String {
  if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
  var buffer = [CChar](repeating: 0, count: 256)
  if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { return String(cString: buffer) }
  return "pid \(pid)"
}

func bit(_ type: CGEventType) -> CGEventMask { CGEventMask(1) << type.rawValue }

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "keys":
  // HID system state: what the keyboard layer itself believes is held, before any event
  // tap or hotkey routing. Without Input Monitoring access every key reads as up, so the
  // access flag travels with the answer.
  var down: [String: Bool] = [:]
  for code in args.dropFirst().compactMap({ UInt16($0) }) {
    down[String(code)] = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))
  }
  emit(["ok": true, "down": down, "listenAccess": CGPreflightListenEventAccess()])

case "taps":
  var count: UInt32 = 0
  guard CGGetEventTapList(0, nil, &count) == .success else {
    emit(["ok": false, "error": "CGGetEventTapList failed"])
  }
  var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
  guard CGGetEventTapList(count, &list, &count) == .success else {
    emit(["ok": false, "error": "CGGetEventTapList failed"])
  }
  let keyEvents = bit(.keyDown) | bit(.keyUp) | bit(.flagsChanged)
  let points = ["hid", "session", "annotated"]
  var taps: [[String: Any]] = []
  for tap in list.prefix(Int(count)) where tap.eventsOfInterest & keyEvents != 0 {
    let point = Int(tap.tapPoint.rawValue)
    taps.append([
      "process": processName(tap.tappingProcess),
      "point": point < points.count ? points[point] : "point \(point)",
      "listenOnly": tap.options == .listenOnly,
      "keyUp": tap.eventsOfInterest & bit(.keyUp) != 0,
      "enabled": tap.enabled,
    ])
  }
  emit(["ok": true, "taps": taps])

case "hold":
  // stepper starts one per press and stops repeating when it exits. The HID system's view
  // comes before every event tap and hotkey route, so it still reports the key-up when
  // macOS loses the hotkey's release, and it doesn't lag the way Hammerspoon's modifier
  // state does while its main thread is busy.
  guard args.count >= 2, let code = UInt16(args[1]) else {
    emit(["ok": false, "error": "usage: inputprobe hold <keycode> [maxSeconds]"])
  }
  guard CGPreflightListenEventAccess() else {
    emit(["ok": false, "error": "no Input Monitoring access"])
  }
  let limit = args.count > 2 ? Double(args[2]) ?? 30 : 30
  let start = Date()
  while CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)) {
    if Date().timeIntervalSince(start) > limit {
      emit(["ok": false, "error": "still held after \(Int(limit)) s"])
    }
    usleep(10_000)
  }
  emit(["ok": true, "heldMs": Int(Date().timeIntervalSince(start) * 1000)])

default:
  emit(["ok": false, "error": "usage: inputprobe keys <keycode>... | inputprobe taps | inputprobe hold <keycode> [maxSeconds]"])
}
