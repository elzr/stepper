// Watches ⌘⇥ while AltTab is running and logs every press that did nothing: no switcher
// on screen and no other window in front. Each such "dead ⌘⇥" becomes one JSON line with
// the evidence that tells the suspects apart. Built, started and kept running by
// cmdtabwatch.lua. Notes: fleet's F040/AltTab subfeature.
//
//   cmdtabwatch --log <file.jsonl> --samples <dir> --pidfile <file>
//               [--key <keycode>] [--panel-owner <bundle id>]
//
// The two bracketed options are for tests: watch ⌘ plus another key, and take another
// app's window at the switcher's level as the switcher.
//
// Both event taps are listen-only, so they can neither delay nor drop a key. They see
// every key-down, but only Tab pressed with ⌘ is looked at, and nothing typed is kept.

import AppKit
import ApplicationServices
import CoreGraphics
import IOKit

// MARK: - Arguments and records

func argument(_ name: String) -> String? {
  let args = CommandLine.arguments
  guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
  return args[i + 1]
}

// Plain globals, not guard bindings: the C event-tap callback below can't capture context
let logPath = argument("--log") ?? ""
let samplesDir = argument("--samples") ?? ""
let pidPath = argument("--pidfile") ?? ""
if logPath.isEmpty || samplesDir.isEmpty || pidPath.isEmpty {
  FileHandle.standardError.write(Data("usage: cmdtabwatch --log <file.jsonl> --samples <dir> --pidfile <file>\n".utf8))
  exit(64)
}
let watchedKey = Int64(argument("--key") ?? "") ?? 48  // 48 = Tab
let chord = watchedKey == 48 ? "⌘⇥" : "⌘key\(watchedKey)"
let altTabBundle = "com.lwouis.alt-tab-macos"
let panelOwner = argument("--panel-owner") ?? altTabBundle
let isTest = watchedKey != 48 || panelOwner != altTabBundle

let clock: ISO8601DateFormatter = {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  f.timeZone = .current
  return f
}()

// One JSON line per event, appended to the log and echoed on stdout for cmdtabwatch.lua.
// "t" and "event" lead; the other fields follow in key order.
func record(_ event: String, _ fields: [String: Any]) {
  var body = "{\"error\":\"fields not encodable as JSON\"}"
  if JSONSerialization.isValidJSONObject(fields),
     let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]) {
    body = String(decoding: data, as: UTF8.self)
  }
  var line = "{\"t\":\"\(clock.string(from: Date()))\",\"event\":\"\(event)\""
  if isTest { line += ",\"test\":true" }
  line += (body == "{}" ? "}" : "," + String(body.dropFirst())) + "\n"
  let data = Data(line.utf8)
  if !FileManager.default.fileExists(atPath: logPath) {
    FileManager.default.createFile(atPath: logPath, contents: nil)
  }
  if let log = FileHandle(forWritingAtPath: logPath) {
    log.seekToEndOfFile()
    log.write(data)
    log.closeFile()
  }
  FileHandle.standardOutput.write(data)
}

func orNull(_ value: Any?) -> Any { value ?? NSNull() }

func oneDecimal(_ x: Double) -> Double { (x * 10).rounded() / 10 }

// MARK: - Processes, displays, windows

func processName(_ pid: pid_t) -> String {
  if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
  var buffer = [CChar](repeating: 0, count: 256)
  if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { return String(cString: buffer) }
  return "pid \(pid)"
}

func running(_ bundle: String) -> NSRunningApplication? {
  NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first { !$0.isTerminated }
}

func version(_ app: NSRunningApplication) -> String {
  app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "?"
}

struct Display { let id: CGDirectDisplayID; let size: CGSize }

func displays() -> [Display] {
  var count = UInt32(0)
  guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
  var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
  guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
  return ids.prefix(Int(count)).map { Display(id: $0, size: CGDisplayBounds($0).size) }
}

func displayList() -> [String] {
  displays().map { "\($0.id) \(Int($0.size.width))×\(Int($0.size.height))" }
}

typealias WindowInfo = [String: Any]

func onScreenWindows() -> [WindowInfo] {
  CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [WindowInfo] ?? []
}

func bounds(_ w: WindowInfo) -> CGRect? {
  (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
}

func layer(_ w: WindowInfo) -> Int { w[kCGWindowLayer as String] as? Int ?? 0 }

func alpha(_ w: WindowInfo) -> Double { w[kCGWindowAlpha as String] as? Double ?? 1 }

func owner(_ w: WindowInfo) -> pid_t { pid_t(w[kCGWindowOwnerPID as String] as? Int ?? -1) }

func describe(_ w: WindowInfo) -> [String: Any] {
  let rect = bounds(w).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" }
  return [
    "layer": layer(w),
    "bounds": rect ?? "none",
    "alpha": oneDecimal(alpha(w)),
    "name": w[kCGWindowName as String] as? String ?? "",  // empty without Screen Recording
    "wid": w[kCGWindowNumber as String] as? Int ?? 0,
  ]
}

// MARK: - What AltTab sees

// AltTab 11.8–11.9's MissionControlOverlay.gesture, replicated. On macOS 27 it is AltTab's
// only way to know that Mission Control or App Exposé is up, and while it says so AltTab
// cancels every summon (Windows.updatesBeforeShowing) and skips every switch
// (App.focusSelectedWindow). A WindowManager surface at the shield's level (19) as large as
// some screen means a gesture: Mission Control with the Spaces bar (14), App Exposé without.
// Level 18 is Show Desktop, which AltTab lets through.
struct Overlay { let verdict: String; let surfaces: [[String: Any]] }

let gestureName = ["missionControl": "Mission Control", "appExpose": "App Exposé",
                   "showDesktop": "Show Desktop", "none": "no gesture"]

func blocksAltTab(_ verdict: String) -> Bool { verdict == "missionControl" || verdict == "appExpose" }

func overlay(_ windows: [WindowInfo]) -> Overlay {
  let sizes = displays().map { $0.size }
  var shield = false, spacesBar = false, showDesktop = false
  var surfaces: [[String: Any]] = []
  for w in windows where w[kCGWindowOwnerName as String] as? String == "WindowManager" {
    guard [14, 18, 19].contains(layer(w)) else { continue }
    let covers = bounds(w).map { r in sizes.contains { r.width >= $0.width && r.height >= $0.height } } ?? false
    switch layer(w) {
    case 19: shield = shield || covers
    case 18: showDesktop = true
    default: spacesBar = true
    }
    var surface = describe(w)
    surface["coversAScreen"] = covers
    surfaces.append(surface)
  }
  let verdict = shield ? (spacesBar ? "missionControl" : "appExpose") : (showDesktop ? "showDesktop" : "none")
  return Overlay(verdict: verdict, surfaces: surfaces)
}

func shieldDescription(_ o: Overlay) -> String {
  guard let s = o.surfaces.first(where: { $0["coversAScreen"] as? Bool == true }) else { return "" }
  let name = (s["name"] as? String).flatMap { $0.isEmpty ? nil : "\"\($0)\" " } ?? ""
  return "WindowManager \(name)\(s["bounds"] ?? "") at level 19, alpha \(s["alpha"] ?? "?")"
}

// The switcher is AltTab's panel at the pop-up menu level (101) once its 100 ms delay is up.
// Below the screen-saver level (1000), where alerts like Hammerspoon's live.
func switcherUp(_ windows: [WindowInfo], _ pid: pid_t?) -> Bool {
  guard let pid else { return false }
  return windows.contains { w in
    owner(w) == pid && (100..<1000).contains(layer(w)) && alpha(w) > 0.01 &&
      (bounds(w).map { $0.width >= 100 && $0.height >= 40 } ?? false)
  }
}

// What a working ⌘⇥ changes: the frontmost app or at least the topmost window
struct Front: Equatable { let pid: pid_t; let wid: Int }

func frontmost(_ windows: [WindowInfo]) -> Front {
  let top = windows.first { layer($0) == 0 }
  return Front(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
               wid: top?[kCGWindowNumber as String] as? Int ?? -1)
}

// AltTab turns its shortcuts off in apps on its Exceptions list ("ignore" 1: always,
// 2: while fullscreen), matching the bundle id as a prefix, as AltTab does
func exceptionMatching(_ bundle: String?, fullscreen: Bool?) -> String? {
  guard let bundle,
        let json = CFPreferencesCopyAppValue("exceptions" as CFString, altTabBundle as CFString) as? String,
        let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: String]] else { return nil }
  return list.first { e in
    guard let id = e["bundleIdentifier"], !id.isEmpty, bundle.hasPrefix(id) else { return false }
    return e["ignore"] == "1" || (e["ignore"] == "2" && fullscreen == true)
  }?["bundleIdentifier"]
}

// MARK: - The rest of the evidence

func modifiers(_ flags: CGEventFlags) -> String {
  var s = ""
  if flags.contains(.maskControl) { s += "⌃" }
  if flags.contains(.maskAlternate) { s += "⌥" }
  if flags.contains(.maskShift) { s += "⇧" }
  if flags.contains(.maskCommand) { s += "⌘" }
  if flags.contains(.maskSecondaryFn) { s += "fn" }
  if flags.contains(.maskAlphaShift) { s += "⇪" }
  return s.isEmpty ? "none" : s
}

let modifierKeys: [(String, CGKeyCode)] = [("⌘L", 55), ("⌘R", 54), ("⇧L", 56), ("⇧R", 60),
                                            ("⌥L", 58), ("⌥R", 61), ("⌃L", 59), ("⌃R", 62), ("fn", 63)]

// What the keyboard layer itself holds (needs Input Monitoring) and what the session believes
func modifierState() -> [String: Any] {
  [
    "session": modifiers(CGEventSource.flagsState(.combinedSessionState)),
    "hid": modifiers(CGEventSource.flagsState(.hidSystemState)),
    "hidKeysDown": modifierKeys.filter { CGEventSource.keyState(.hidSystemState, key: $0.1) }.map { $0.0 },
    "listenAccess": CGPreflightListenEventAccess(),
  ]
}

func bit(_ type: CGEventType) -> CGEventMask { CGEventMask(1) << type.rawValue }

func microseconds(_ x: Float) -> Int { x.isFinite ? Int(x) : -1 }

// Every event tap on key events, as in inputprobe.swift, plus how slow each one is
func tapCensus() -> [[String: Any]] {
  var count: UInt32 = 0
  guard CGGetEventTapList(0, nil, &count) == .success else { return [] }
  var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
  guard CGGetEventTapList(count, &list, &count) == .success else { return [] }
  let keyEvents = bit(.keyDown) | bit(.keyUp) | bit(.flagsChanged)
  let points = ["hid", "session", "annotated"]
  return list.prefix(Int(count)).filter { $0.eventsOfInterest & keyEvents != 0 }.map { tap in
    let point = Int(tap.tapPoint.rawValue)
    return [
      "process": processName(tap.tappingProcess),
      "point": point < points.count ? points[point] : "point \(point)",
      "listenOnly": tap.options == .listenOnly,
      "enabled": tap.enabled,
      "avgLatencyUs": microseconds(tap.avgUsecLatency),
      "maxLatencyUs": microseconds(tap.maxUsecLatency),
    ]
  }
}

func secureInput() -> [String: Any] {
  let root = IORegistryGetRootEntry(kIOMainPortDefault)
  defer { IOObjectRelease(root) }
  guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
          .takeRetainedValue() as? [[String: Any]] else { return ["known": false] }
  for user in users {
    if let pid = user["kCGSSessionSecureInputPID"] as? Int, pid > 0 {
      return ["on": true, "pid": pid, "process": processName(pid_t(pid))]
    }
  }
  return ["on": false]
}

// AltTab switches the Dock's own ⌘⇥ (symbolic hotkey 1) off while it owns the chord, so
// when AltTab drops a press nothing else will catch it
typealias SymbolicHotKeyQuery = @convention(c) (Int32) -> Bool
let isSymbolicHotKeyEnabled: SymbolicHotKeyQuery? = {
  guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
        let symbol = dlsym(skyLight, "CGSIsSymbolicHotKeyEnabled") else { return nil }
  return unsafeBitCast(symbol, to: SymbolicHotKeyQuery.self)
}()

func stageManager() -> Any {
  orNull(CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool)
}

func lastWake() -> Date? {
  var time = timeval()
  var size = MemoryLayout<timeval>.size
  guard sysctlbyname("kern.waketime", &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
  return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
}

var lastUnlock: Date?

func minutesSince(_ date: Date?) -> Any { orNull(date.map { oneDecimal(Date().timeIntervalSince($0) / 60) }) }

// Accessibility requests are served on the app's main thread, so an answer within the
// timeout means AltTab's main thread is free to take its hotkeys
func axProbe(_ pid: pid_t) -> [String: Any] {
  let app = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(app, 1)
  var value: CFTypeRef?
  let start = Date()
  let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
  return ["answered": error == .success, "ms": Int(Date().timeIntervalSince(start) * 1000),
          "axError": Int(error.rawValue)]
}

func isFullscreen(_ pid: pid_t) -> Bool? {
  let app = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(app, 0.5)
  var window: CFTypeRef?
  guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
        let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &value) == .success else {
    return nil
  }
  return value as? Bool
}

// MARK: - Stack samples

let fileClock: DateFormatter = {
  let f = DateFormatter()
  f.dateFormat = "yyyy-MM-dd'T'HHmmss"
  return f
}()

// Whether AltTab's main thread spent the sample waiting in its run loop, i.e. idle and
// free to take a hotkey. In `sample`'s call tree the main thread's line carries the number
// of samples, and the __CFRunLoopServiceMachPort frame how many of them were spent waiting.
func mainThreadSummary(_ path: String) -> [String: Any] {
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return ["read": false] }
  let lines = text.components(separatedBy: "\n")
  // "DispatchQueue_1: com.apple.main-thread", or "Main Thread" when it ran several queues
  guard let start = lines.firstIndex(where: { $0.contains(" Thread_") &&
          ($0.contains("com.apple.main-thread") || $0.contains("Main Thread")) }) else { return ["read": false] }
  func count(_ line: String) -> Int { Int(String(line.drop { !$0.isNumber }.prefix { $0.isNumber })) ?? 0 }
  let total = count(lines[start])
  var waiting = 0
  for line in lines[(start + 1)...] {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || (trimmed.first?.isNumber == true && trimmed.contains(" Thread_")) { break }  // next thread
    if line.contains("__CFRunLoopServiceMachPort") { waiting = max(waiting, count(line)) }
  }
  return ["samples": total, "waitingInRunLoop": waiting, "idle": total > 0 && waiting * 10 >= total * 9]
}

func sampleAltTab(_ pid: pid_t, episodeStarted: String) {
  try? FileManager.default.createDirectory(atPath: samplesDir, withIntermediateDirectories: true)
  let file = samplesDir + "/alttab-" + fileClock.string(from: Date()) + ".txt"
  let sample = Process()
  sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
  sample.arguments = [String(pid), "1", "-file", file]
  sample.standardOutput = FileHandle.nullDevice
  sample.standardError = FileHandle.nullDevice
  sample.terminationHandler = { _ in
    DispatchQueue.main.async {
      let main = mainThreadSummary(file)
      let idle = main["idle"] as? Bool
      record("sample", [
        "episodeStarted": episodeStarted, "file": file, "mainThread": main,
        "summary": "AltTab's main thread was " + (idle == nil ? "unreadable" : idle! ? "idle (waiting for events)" : "busy or blocked") + " · \(file)",
      ])
      pruneSamples()
    }
  }
  do { try sample.run() } catch { record("sample", ["error": "\(error)"]) }
}

func pruneSamples(keep: Int = 30) {
  let fm = FileManager.default
  guard let names = try? fm.contentsOfDirectory(atPath: samplesDir) else { return }
  let samples = names.filter { $0.hasPrefix("alttab-") && $0.hasSuffix(".txt") }.sorted()
  for name in samples.dropLast(keep) { try? fm.removeItem(atPath: samplesDir + "/" + name) }
}

// MARK: - Watching presses

// One hold of ⌘ with one or more ⇥ in it
final class Gesture {
  let started = ProcessInfo.processInfo.systemUptime
  let front: Front
  let atPress: Overlay  // what AltTab's Exposé check read when the key went down
  let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName
  var hidTabs = 0, sessionTabs = 0
  var hidFlags: CGEventFlags?, sessionFlags: CGEventFlags?
  var strippedTabs = 0  // ⇥ that reached the session without the ⌘ the HID tap saw
  var strippedFlags: CGEventFlags?
  var releasedAt: TimeInterval?
  init(_ windows: [WindowInfo]) {
    front = frontmost(windows)
    atPress = overlay(windows)
  }
}

// Dead presses in a row, until a press works again
final class Episode {
  let started = Date()
  var dead = 0
  var alerted = false
}

var hidTap: CFMachPort?
var sessionTap: CFMachPort?
var gesture: Gesture?
var gestureTimer: Timer?
var episode: Episode?
var okPresses = 0, deadPresses = 0, cutShort = 0

func tabPressed(atHID: Bool, flags: CGEventFlags) {
  // ⇥ after ⌘ came up is the next gesture (⌘⇥ ⌘⇥ to flip back and forth). Judged now,
  // the last one is proven only by a change already visible; without one it isn't judged
  // at all, since a dead ⌘⇥ pressed again and again still gets its last press judged.
  if let g = gesture, g.releasedAt != nil {
    if let how = proof(g, onScreenWindows()) {
      conclude(g, worked: how)
    } else {
      endGesture()
      cutShort += 1
    }
  }
  if gesture == nil {
    // ⌘⇧⇥ only means something once the switcher is up
    guard !flags.contains(.maskShift), isTest || running(altTabBundle) != nil else { return }
    gesture = Gesture(onScreenWindows())
    gestureTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in tick() }
  }
  guard let g = gesture else { return }
  if atHID {
    g.hidTabs += 1
    g.hidFlags = g.hidFlags ?? flags
  } else {
    g.sessionTabs += 1
    g.sessionFlags = g.sessionFlags ?? flags
  }
}

// ⌘ coming up, from the session tap, so a quick ⌘⇥ ⌘⇥ isn't read as one long hold
func flagsChanged(_ flags: CGEventFlags) {
  if let g = gesture, g.releasedAt == nil, !flags.contains(.maskCommand) {
    g.releasedAt = ProcessInfo.processInfo.systemUptime
  }
}

// What shows a gesture worked: the switcher on screen, or another app or window in front.
// A quick tap never shows the switcher (AltTab waits 100 ms), so the change proves those.
func proof(_ g: Gesture, _ windows: [WindowInfo]) -> String? {
  if switcherUp(windows, running(panelOwner)?.processIdentifier) { return "switcher" }
  let now = frontmost(windows)
  if now.pid != g.front.pid { return "front app" }
  if now.wid != g.front.wid { return "front window" }
  return nil
}

// With no proof 1 s after ⌘ came up, the press was dead
func tick() {
  guard let g = gesture else { return }
  let now = ProcessInfo.processInfo.systemUptime
  if let how = proof(g, onScreenWindows()) { return conclude(g, worked: how) }
  if g.releasedAt == nil, !CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) {
    g.releasedAt = now
  }
  if let released = g.releasedAt, now - released >= 1, now - g.started >= 1.2 {
    return conclude(g, worked: nil)
  }
  if now - g.started >= 6 { conclude(g, worked: nil, stillHeld: true) }
}

func endGesture() {
  gestureTimer?.invalidate()
  gestureTimer = nil
  gesture = nil
}

func conclude(_ g: Gesture, worked how: String?, stillHeld: Bool = false) {
  endGesture()
  if let how { pressWorked(g, how) } else { pressWasDead(g, stillHeld: stillHeld) }
}

func pressWorked(_ g: Gesture, _ how: String) {
  okPresses += 1
  if isTest {
    record("worked", ["how": how, "frontBefore": orNull(g.frontApp),
                      "frontNow": orNull(NSWorkspace.shared.frontmostApplication?.localizedName)])
  }
  guard let e = episode else { return }
  episode = nil
  let minutes = Date().timeIntervalSince(e.started) / 60
  let now = overlay(onScreenWindows()).verdict
  record("recovered", [
    "episodeStarted": clock.string(from: e.started), "lastedMin": oneDecimal(minutes),
    "deadPresses": e.dead, "missionControl": now, "how": how,
    "summary": "\(chord) works again after \(oneDecimal(minutes)) min and \(e.dead) dead press\(e.dead == 1 ? "" : "es") · AltTab now reads \(gestureName[now] ?? now)",
  ])
}

// Everything known about a dead press, gathered when it is judged. The Accessibility
// part arrives later, off the main thread.
struct Scene {
  let gesture: Gesture
  let stillHeld: Bool
  let seen: Overlay
  let altTab: NSRunningApplication?
  let altTabWindows: [[String: Any]]
  let frontApp: NSRunningApplication?
  let modifiers: [String: Any]
  let taps: [[String: Any]]
  var ax: [String: Any]?
  var fullscreen: Bool?
  var exception: String?
}

struct Suspect { let code: String; let detail: String; let alert: String }

func gestureSuspect(_ o: Overlay, when: String, unseen: Bool) -> Suspect {
  let name = gestureName[o.verdict] ?? o.verdict
  let also = unseen ? "; the key never reached the end of the session taps either" : ""
  return Suspect(code: "alttab-sees-gesture",
                 detail: "AltTab read \(name) on screen \(when) (\(shieldDescription(o))): it ignores ⌘⇥ while one is up, rightly if it really was\(also)",
                 alert: "AltTab thinks \(name) is on screen")
}

// The first suspect that fits, in the order the evidence is conclusive
func diagnose(_ s: Scene) -> Suspect {
  let g = s.gesture
  let flags: CGEventFlags = g.sessionFlags ?? g.hidFlags ?? []
  let keys = s.modifiers["hidKeysDown"] as? [String] ?? []
  let held = keys.isEmpty ? "nothing" : keys.joined(separator: " ")
  let unseen = hidTap != nil && g.hidTabs > 0 && g.sessionTabs == 0
  if blocksAltTab(g.atPress.verdict) {
    return gestureSuspect(g.atPress, when: "as the key went down", unseen: unseen)
  }
  if unseen, g.strippedTabs > 0 {
    let arrived = modifiers(g.strippedFlags ?? [])
    return Suspect(code: "modifier",
                   detail: "⌘ was taken off the key between the HID tap and the session's end: it arrived as \(arrived == "none" ? "plain" : arrived) ⇥",
                   alert: "⌘ was stripped off the key before any app saw it")
  }
  if unseen {
    // Filtering taps at the HID point, or at the session point ahead of ours (we are last there)
    let filters: [String] = s.taps.compactMap { tap in
      guard tap["listenOnly"] as? Bool == false, tap["enabled"] as? Bool == true,
            let point = tap["point"] as? String, point == "hid" || point == "session",
            let process = tap["process"] as? String, process != "cmdtabwatch" else { return nil }
      return "\(process) (\(point))"
    }
    let list = filters.isEmpty ? "none listed" : Array(Set(filters)).sorted().joined(separator: ", ")
    let after = blocksAltTab(s.seen.verdict) ? " · \(gestureName[s.seen.verdict] ?? s.seen.verdict) was on screen just after" : ""
    return Suspect(code: "swallowed",
                   detail: "the key reached the HID tap but not the end of the session taps: a filtering tap in between took it (\(list))\(after)",
                   alert: "the key was swallowed before reaching any app")
  }
  if !flags.intersection([.maskControl, .maskAlternate]).isEmpty {
    return Suspect(code: "modifier",
                   detail: "it arrived as \(modifiers(flags)) + key, not plain \(chord) · HID holds: \(held)",
                   alert: "it arrived as \(modifiers(flags)) + key: a modifier held or stuck")
  }
  if s.stillHeld {
    return Suspect(code: "modifier", detail: "⌘ still down 6 s after the press (HID holds: \(held)): a lost ⌘ key-up?",
                   alert: "⌘ looks stuck down")
  }
  if let ax = s.ax, ax["answered"] as? Bool == false {
    return Suspect(code: "alttab-hung",
                   detail: "AltTab didn't answer Accessibility within 1 s: its main thread is stuck (a stack sample follows)",
                   alert: "AltTab isn't responding")
  }
  if blocksAltTab(s.seen.verdict) {
    return gestureSuspect(s.seen, when: "just after the press", unseen: false)
  }
  if let exception = s.exception {
    let app = s.frontApp?.localizedName ?? "the front app"
    return Suspect(code: "alttab-exception",
                   detail: "\(app) is on AltTab's Exceptions list (\(exception)), which turns its shortcuts off",
                   alert: "AltTab is off in this app (Exceptions)")
  }
  let invisible = s.altTabWindows.contains { w in
    (w["layer"] as? Int ?? 0) >= 100 && (w["alpha"] as? Double ?? 1) <= 0.01
  }
  if invisible {
    return Suspect(code: "panel-invisible", detail: "AltTab's switcher is on screen but fully transparent",
                   alert: "AltTab's switcher is up but invisible")
  }
  if s.altTab == nil {
    return Suspect(code: "alttab-gone", detail: "AltTab is not running", alert: "AltTab is not running")
  }
  return Suspect(code: "unexplained",
                 detail: "AltTab answers, sees no gesture, and \(chord) reached the session: open AltTab ▸ Debug Tools and press \(chord) once to capture its own log",
                 alert: "no cause in sight: open AltTab ▸ Debug Tools")
}

func pressFields(_ g: Gesture, stillHeld: Bool) -> [String: Any] {
  let end = g.releasedAt ?? ProcessInfo.processInfo.systemUptime
  var press: [String: Any] = [:]
  press["heldMs"] = Int((end - g.started) * 1000)
  press["stillHeld"] = stillHeld
  press["tabs"] = max(g.hidTabs, g.sessionTabs)
  press["seenAtHID"] = hidTap == nil ? NSNull() : NSNumber(value: g.hidTabs > 0)
  press["reachedSession"] = g.sessionTabs > 0
  press["hidFlags"] = g.hidFlags.map { modifiers($0) } ?? "unseen"
  press["sessionFlags"] = g.sessionFlags.map { modifiers($0) } ?? "unseen"
  press["strippedFlags"] = orNull(g.strippedFlags.map { modifiers($0) })
  press["frontBefore"] = orNull(g.frontApp)
  return press
}

func sceneFields(_ s: Scene) -> [String: Any] {
  var altTab: [String: Any] = ["running": s.altTab != nil, "windows": s.altTabWindows]
  altTab["version"] = orNull(s.altTab.map { version($0) })
  altTab["pid"] = orNull(s.altTab.map { Int($0.processIdentifier) })
  altTab["ax"] = orNull(s.ax)
  var front: [String: Any] = [:]
  front["app"] = orNull(s.frontApp?.localizedName)
  front["bundle"] = orNull(s.frontApp?.bundleIdentifier)
  front["fullscreen"] = orNull(s.fullscreen)
  front["altTabException"] = orNull(s.exception)
  var fields: [String: Any] = [:]
  fields["press"] = pressFields(s.gesture, stillHeld: s.stillHeld)
  fields["missionControl"] = ["verdict": s.seen.verdict, "surfaces": s.seen.surfaces,
                              "atPress": s.gesture.atPress.verdict,
                              "surfacesAtPress": s.gesture.atPress.surfaces] as [String: Any]
  fields["altTab"] = altTab
  fields["front"] = front
  fields["modifiers"] = s.modifiers
  fields["taps"] = s.taps
  fields["displays"] = displayList()
  fields["stageManager"] = stageManager()
  fields["secureInput"] = secureInput()
  let native: Bool? = isSymbolicHotKeyEnabled?(1)
  fields["nativeCommandTab"] = orNull(native)
  fields["sinceWakeMin"] = minutesSince(lastWake())
  fields["sinceUnlockMin"] = minutesSince(lastUnlock)
  return fields
}

func pressWasDead(_ g: Gesture, stillHeld: Bool) {
  deadPresses += 1
  let e = episode ?? Episode()
  episode = e
  e.dead += 1
  let windows = onScreenWindows()
  let altTab = running(altTabBundle)
  let altTabWindows: [[String: Any]] = windows.filter { owner($0) == altTab?.processIdentifier }.map { describe($0) }
  let judged = Scene(gesture: g, stillHeld: stillHeld, seen: overlay(windows), altTab: altTab,
                     altTabWindows: altTabWindows, frontApp: NSWorkspace.shared.frontmostApplication,
                     modifiers: modifierState(), taps: tapCensus(), ax: nil, fullscreen: nil, exception: nil)
  // Accessibility answers can take up to their timeout: off the main thread
  let altTabPid: pid_t? = altTab?.processIdentifier
  let frontPid: pid_t? = judged.frontApp?.processIdentifier
  DispatchQueue.global(qos: .utility).async {
    let ax: [String: Any]? = altTabPid.map { axProbe($0) }
    let fullscreen: Bool? = frontPid.flatMap { isFullscreen($0) }
    DispatchQueue.main.async {
      var scene = judged
      scene.ax = ax
      scene.fullscreen = fullscreen
      scene.exception = exceptionMatching(scene.frontApp?.bundleIdentifier, fullscreen: fullscreen)
      let suspect = diagnose(scene)
      var fields = sceneFields(scene)
      let started = clock.string(from: e.started)
      fields["episodeStarted"] = started
      fields["deadInEpisode"] = e.dead
      fields["suspect"] = suspect.code
      fields["alert"] = suspect.alert
      // One alert per episode: at once when there is evidence, and with nothing to show
      // only once a second press confirms it (a lone press can be a misjudged one)
      let alertNow = !e.alerted && (suspect.code != "unexplained" || e.dead >= 2)
      if alertNow { e.alerted = true }
      fields["alertNow"] = alertNow
      let place = e.dead == 1 ? "starts an episode" : "#\(e.dead) of this episode"
      fields["summary"] = "dead \(chord) (\(place)) · \(suspect.detail)"
      record("dead", fields)
      if e.dead == 1, let altTabPid { sampleAltTab(altTabPid, episodeStarted: started) }
    }
  }
}

// MARK: - Watching AltTab's view between presses

// When a gesture reading lasts past one poll it is logged, and again when it goes away. A
// real App Exposé comes and goes with the user; one that outlives it is AltTab's false alarm.
var shownSince: (verdict: String, since: Date, logged: Bool)?

func pollOverlay() {
  guard running(altTabBundle) != nil else { return endOverlay() }
  let seen = overlay(onScreenWindows())
  guard blocksAltTab(seen.verdict) else { return endOverlay() }
  if let shown = shownSince, shown.verdict == seen.verdict {
    if !shown.logged {
      shownSince?.logged = true
      record("overlay", [
        "verdict": seen.verdict, "surfaces": seen.surfaces, "displays": displayList(),
        "summary": "AltTab now reads \(gestureName[seen.verdict]!) (\(shieldDescription(seen)))",
      ])
    }
  } else {
    endOverlay()
    shownSince = (seen.verdict, Date(), false)
  }
}

func endOverlay() {
  guard let shown = shownSince else { return }
  shownSince = nil
  guard shown.logged else { return }
  let seconds = Int(Date().timeIntervalSince(shown.since))
  record("overlay-gone", ["verdict": shown.verdict, "lastedSec": seconds,
                          "summary": "AltTab stopped reading \(gestureName[shown.verdict]!) after \(seconds) s"])
}

// MARK: - Taps and startup

var lastReenableRecord = Date.distantPast

// Key-downs each tap saw (counts only): both should see the same typing, and a tap that
// sees none while the other counts is blind, which would hide or fake a swallowed key
var hidKeyDowns = 0, sessionKeyDowns = 0
var tapsChecked = false

// Once per run, after some typing (synthetic keys posted to the session never pass the HID tap)
func checkTapsOnce() {
  tapsChecked = true
  let verdict = hidTap != nil && hidKeyDowns == 0 ? "the HID tap saw none: a swallowed key can't be told apart" : "both taps see typing"
  record("taps-live", ["hidKeyDowns": hidKeyDowns, "sessionKeyDowns": sessionKeyDowns,
                       "summary": "first key-downs: HID \(hidKeyDowns), session \(sessionKeyDowns) · \(verdict)"])
}

let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
  let atHID = refcon != nil  // only the HID tap carries a refcon
  switch type {
  case .flagsChanged:
    if !atHID { flagsChanged(event.flags) }
  case .keyDown:
    if atHID { hidKeyDowns += 1 } else { sessionKeyDowns += 1 }
    if !atHID, !tapsChecked, sessionKeyDowns >= 20 { checkTapsOnce() }
    if event.getIntegerValueField(.keyboardEventKeycode) == watchedKey,
       event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
      if event.flags.contains(.maskCommand) {
        tabPressed(atHID: atHID, flags: event.flags)
      } else if !atHID, let g = gesture, g.hidTabs > g.sessionTabs + g.strippedTabs {
        // The HID tap saw ⌘ on this ⇥, the session doesn't: a tap in between took ⌘ away
        g.strippedTabs += 1
        g.strippedFlags = g.strippedFlags ?? event.flags
      }
    }
  case .tapDisabledByTimeout, .tapDisabledByUserInput:
    if let tap = atHID ? hidTap : sessionTap { CGEvent.tapEnable(tap: tap, enable: true) }
    if Date().timeIntervalSince(lastReenableRecord) > 600 {
      lastReenableRecord = Date()
      record("tap-reenabled", ["tap": atHID ? "hid" : "session",
                               "why": type == .tapDisabledByTimeout ? "timeout" : "user input"])
    }
  default:
    break
  }
  return Unmanaged.passUnretained(event)
}

func makeTap(_ point: CGEventTapLocation, _ place: CGEventTapPlacement, _ refcon: UnsafeMutableRawPointer?) -> CFMachPort? {
  guard let tap = CGEvent.tapCreate(tap: point, place: place, options: .listenOnly,
                                    eventsOfInterest: bit(.keyDown) | bit(.flagsChanged),
                                    callback: tapCallback, userInfo: refcon) else { return nil }
  CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
  CGEvent.tapEnable(tap: tap, enable: true)
  return tap
}

// One watcher at a time: a Hammerspoon reload starts a new one, which retires the old
func retirePrevious() -> Int? {
  guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
        let old = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), old != getpid() else { return nil }
  var buffer = [CChar](repeating: 0, count: 256)
  guard proc_name(old, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == "cmdtabwatch" else { return nil }
  kill(old, SIGTERM)
  return Int(old)
}

let replaced = retirePrevious()
try? "\(getpid())\n".write(toFile: pidPath, atomically: true, encoding: .utf8)

// The HID tap sees a press first, the session tap after every other tap had its turn:
// a press seen only by the first was swallowed in between
hidTap = makeTap(.cghidEventTap, .headInsertEventTap, UnsafeMutableRawPointer(bitPattern: 1))
sessionTap = makeTap(.cgSessionEventTap, .tailAppendEventTap, nil)
guard hidTap != nil || sessionTap != nil else {
  record("error", ["summary": "no event tap could be created: Hammerspoon needs Accessibility (or Input Monitoring)"])
  exit(3)
}

let altTabAtStart = running(altTabBundle)
let tapNames = [hidTap != nil ? "hid" : nil, sessionTap != nil ? "session" : nil].compactMap { $0 }.joined(separator: "+")
record("start", [
  "pid": Int(getpid()), "replaced": orNull(replaced), "altTab": orNull(altTabAtStart.map(version)),
  "taps": tapNames, "listenAccess": CGPreflightListenEventAccess(), "axTrusted": AXIsProcessTrusted(),
  "displays": displayList(), "stageManager": stageManager(),
  "summary": "watching \(chord) for AltTab \(altTabAtStart.map(version) ?? "(not running)") · taps: \(tapNames) · Accessibility \(AXIsProcessTrusted() ? "yes" : "NO")",
])

DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                                    object: nil, queue: .main) { _ in lastUnlock = Date() }

Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in pollOverlay() }

// An hourly heartbeat while the keyboard is in use
Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
  guard sessionKeyDowns + hidKeyDowns > 0 else { return }
  record("tally", ["ok": okPresses, "dead": deadPresses, "cutShort": cutShort,
                   "hidKeyDowns": hidKeyDowns, "sessionKeyDowns": sessionKeyDowns,
                   "summary": "past hour: \(okPresses) \(chord) worked, \(deadPresses) dead, \(cutShort) cut short by the next · key-downs seen: HID \(hidKeyDowns), session \(sessionKeyDowns)"])
  okPresses = 0
  deadPresses = 0
  cutShort = 0
  hidKeyDowns = 0
  sessionKeyDowns = 0
}

// Hammerspoon gone (we were handed to launchd): nobody is reading, stop
Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
  if getppid() == 1 {
    record("stop", ["summary": "Hammerspoon is gone; stopping"])
    exit(0)
  }
}

RunLoop.main.run()
