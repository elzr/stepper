// Reads the windows a layout save records, for layout.lua, in a process of its own: an app
// that is slow to answer Accessibility holds up this helper, never Hammerspoon's main
// thread, where stepper's hotkeys run. Built by layout.lua on first use; prints one JSON
// document.
//
//   layoutsnap [axTimeoutSeconds] [deadlineSeconds]
//
// The windows are the ones hs.window.orderedWindows() returns: on screen, not minimized,
// of unhidden regular apps, front to back. Apps are read in parallel, each Accessibility
// call waits at most axTimeoutSeconds, and the apps that haven't answered by
// deadlineSeconds are listed in "failed", so layout.lua keeps their last saved windows.
// See changelog/2026-10-09-layout-saves-off-the-main-thread.md

import AppKit
import ApplicationServices

// The window id hs.window:id() returns, from the Accessibility element (private, stable)
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func emit(_ doc: [String: Any]) -> Never {
  let data = (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]))
    ?? Data("{\"ok\":false,\"error\":\"unencodable result\"}".utf8)
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
  exit(doc["ok"] as? Bool == true ? 0 : 1)
}

func msSince(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

// Attribute values come back as AXValues, or as an AXValue holding the error
func asAXValue(_ value: AnyObject, _ type: AXValueType) -> AXValue? {
  guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
  let ax = value as! AXValue
  return AXValueGetType(ax) == type ? ax : nil
}

func point(_ value: AnyObject) -> CGPoint? {
  var result = CGPoint.zero
  guard let ax = asAXValue(value, .cgPoint), AXValueGetValue(ax, .cgPoint, &result) else { return nil }
  return result
}

func size(_ value: AnyObject) -> CGSize? {
  var result = CGSize.zero
  guard let ax = asAXValue(value, .cgSize), AXValueGetValue(ax, .cgSize, &result) else { return nil }
  return result
}

let args = Array(CommandLine.arguments.dropFirst())
let axTimeout = args.count > 0 ? Float(args[0]) ?? 1 : 1
let deadline = args.count > 1 ? Double(args[1]) ?? 4 : 4
let started = Date()

guard AXIsProcessTrusted() else { emit(["ok": false, "error": "no Accessibility access"]) }
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axTimeout)

// Front to back, from the WindowServer, which answers for every app at once
func onScreenOrder() -> (zOrder: [CGWindowID: Int], pids: [pid_t]) {
  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                        kCGNullWindowID) as? [[String: Any]] ?? []
  var zOrder: [CGWindowID: Int] = [:]
  var pids: [pid_t] = []
  for (z, info) in list.enumerated() {
    guard let id = info[kCGWindowNumber as String] as? CGWindowID,
          let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
    zOrder[id] = z
    if !pids.contains(pid) { pids.append(pid) }
  }
  return (zOrder, pids)
}
let (zOrder, pids) = onScreenOrder()

// hs.window.orderedWindows() skips apps that aren't regular (kind() <= 0) or are hidden
struct App: Sendable { let pid: pid_t; let name: String }
var apps: [App] = []
for pid in pids {
  guard let app = NSRunningApplication(processIdentifier: pid),
        app.activationPolicy == .regular, !app.isHidden else { continue }
  apps.append(App(pid: pid, name: app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"))
}

struct Reading { var windows: [[String: Any]] = []; var error: String? = nil; var ms = 0 }

func readWindows(_ app: App, _ zOrder: [CGWindowID: Int]) -> Reading {
  var reading = Reading()
  var value: CFTypeRef?
  let listed = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.pid),
                                             kAXWindowsAttribute as CFString, &value)
  // Other errors mean no windows to read, as hs.application:allWindows() treats them
  if listed == .cannotComplete { reading.error = "no answer"; return reading }
  guard listed == .success, let elements = value as? [AXUIElement] else { return reading }
  // One round trip per window for everything a save needs
  let attributes = [kAXTitleAttribute, kAXSubroleAttribute, kAXPositionAttribute,
                    kAXSizeAttribute, kAXMinimizedAttribute] as CFArray
  for element in elements {
    var id: CGWindowID = 0
    guard _AXUIElementGetWindow(element, &id) == .success, let z = zOrder[id] else { continue }
    var raw: CFArray?
    let copied = AXUIElementCopyMultipleAttributeValues(
      element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
    if copied == .cannotComplete { reading.windows = []; reading.error = "no answer"; return reading }
    guard copied == .success, let values = raw as? [AnyObject], values.count == 5 else { continue }
    if values[4] as? Bool == true { continue }
    guard let origin = point(values[2]), let extent = size(values[3]) else { continue }
    reading.windows.append([
      "id": Int(id), "z": z, "pid": Int(app.pid), "app": app.name,
      "title": values[0] as? String ?? "", "subrole": values[1] as? String ?? "",
      "x": Double(origin.x), "y": Double(origin.y),
      "w": Double(extent.width), "h": Double(extent.height),
    ])
  }
  return reading
}

// Filled by one thread per app; whatever is missing at the deadline didn't answer
final class Readings: @unchecked Sendable {
  private let lock = NSLock()
  private var byPid: [pid_t: Reading] = [:]
  func store(_ pid: pid_t, _ reading: Reading) { lock.lock(); byPid[pid] = reading; lock.unlock() }
  func snapshot() -> [pid_t: Reading] { lock.lock(); defer { lock.unlock() }; return byPid }
}

let readings = Readings()
let group = DispatchGroup()
for app in apps {
  group.enter()
  DispatchQueue.global(qos: .userInitiated).async { [zOrder] in
    let start = Date()
    var reading = readWindows(app, zOrder)
    reading.ms = msSince(start)
    readings.store(app.pid, reading)
    group.leave()
  }
}
_ = group.wait(timeout: .now() + deadline)

let answered = readings.snapshot()
var windows: [[String: Any]] = []
var failed: [[String: Any]] = []
var slow: [String] = []
for app in apps {
  guard let reading = answered[app.pid] else {
    failed.append(["app": app.name, "pid": Int(app.pid), "error": "no answer in \(deadline) s"])
    continue
  }
  if let error = reading.error {
    failed.append(["app": app.name, "pid": Int(app.pid), "error": error, "ms": reading.ms])
  } else {
    windows += reading.windows
  }
  if reading.ms >= 100 { slow.append("\(app.name) \(reading.ms) ms") }
}
windows.sort { ($0["z"] as! Int) < ($1["z"] as! Int) }

emit(["ok": true, "ms": msSince(started), "apps": apps.count,
      "windows": windows, "failed": failed, "slow": slow])
