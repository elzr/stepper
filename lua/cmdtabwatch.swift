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
// Its three event taps are listen-only, so they can neither delay nor drop a key. They see
// every key-down, but only Tab pressed with ⌘ is looked at, and nothing typed is kept.
// When another app's tap holds the key, the watcher names that app (see "Holds" below).

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
// AltTab's own debug log, when cmdtabwatch.lua runs it with --logs=debug (rotated to <log>.1)
let altTabLogPath = argument("--alttab-log")

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

// Every event tap on key events, as in inputprobe.swift
func tapList() -> [CGEventTapInformation] {
  var count: UInt32 = 0
  guard CGGetEventTapList(0, nil, &count) == .success else { return [] }
  var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
  guard CGGetEventTapList(count, &list, &count) == .success else { return [] }
  let keyEvents = bit(.keyDown) | bit(.keyUp) | bit(.flagsChanged)
  return list.prefix(Int(count)).filter { $0.eventsOfInterest & keyEvents != 0 }
}

func pointName(_ tap: CGEventTapInformation) -> String {
  let point = Int(tap.tapPoint.rawValue)
  let points = ["hid", "session", "annotated"]
  return point < points.count ? points[point] : "point \(point)"
}

// The taps that can hold a key before the session's end: other apps' enabled filters at the
// HID and session points (annotated taps come after it)
func filtersAhead(enabledOnly: Bool = true) -> [CGEventTapInformation] {
  let me = getpid()
  return tapList().filter { tap in
    tap.options != .listenOnly && tap.tappingProcess != me && (tap.enabled || !enabledOnly) &&
      ["hid", "session"].contains(pointName(tap))
  }
}

// Each tap and how slow macOS says it is. Those figures can't name a stalled app: after a
// stall they jump on every tap at once, upstream of it too (Siri's read 3.1 s at 15:12 on
// 2026-10-09, while Hammerspoon alone was frozen). The "Holds" section below can.
func tapCensus() -> [[String: Any]] {
  tapList().map { tap in
    [
      "process": processName(tap.tappingProcess),
      "pid": Int(tap.tappingProcess),
      "point": pointName(tap),
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

// MARK: - AltTab's own log

// Run with --logs=debug, AltTab prints what it does with every hotkey, and cmdtabwatch.lua
// points that stdout at altTabLogPath. Lines start "HH:mm:ss.SSS LEVEL File.swift:N func()
// [thread]" in ANSI colors, and reach the file in 16 KB chunks: a quiet AltTab can be ~30 s behind.

func altTabRunsWithLog(_ pid: pid_t) -> Bool {
  let ps = Process()
  ps.executableURL = URL(fileURLWithPath: "/bin/ps")
  ps.arguments = ["-o", "args=", "-p", String(pid)]
  let pipe = Pipe()
  ps.standardOutput = pipe
  ps.standardError = FileHandle.nullDevice
  guard (try? ps.run()) != nil else { return false }
  let args = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  ps.waitUntilExit()
  return args.contains("--logs=")
}

func secondsOfDay(_ date: Date) -> Double {
  let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
  return Double((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)) + Double(c.nanosecond ?? 0) / 1e9
}

struct LogLine { let at: Double; let text: String }  // at: seconds into the day

// The end of a log as timestamped lines, colors stripped, each cut to 300 characters
func logTail(_ path: String, bytes: UInt64 = 4 << 20) -> [LogLine] {
  guard let file = FileHandle(forReadingAtPath: path) else { return [] }
  defer { file.closeFile() }
  let size = file.seekToEndOfFile()
  file.seek(toFileOffset: size > bytes ? size - bytes : 0)
  let text = String(decoding: file.readDataToEndOfFile(), as: UTF8.self)
    .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
  return text.split(separator: "\n").compactMap { line in
    let clock = line.prefix(12).split(separator: ":")
    guard clock.count == 3, let h = Double(clock[0]), let m = Double(clock[1]), let s = Double(clock[2]) else { return nil }
    return LogLine(at: h * 3600 + m * 60 + s, text: String(line.prefix(300)))
  }
}

// Once AltTab's log has caught up past a dead press, the lines around it and what they say:
// whether AltTab heard the hotkey, whether it started a summon and cancelled it at once (no
// focus in between: its Exposé check at work), and its last Exposé reading before the press
func excerptAltTabLog(pressedAt: Date, judgedAt: Date, episodeStarted: String, deadInEpisode: Int) {
  guard let path = altTabLogPath else { return }
  let from = secondsOfDay(pressedAt) - 3, to = secondsOfDay(judgedAt) + 1
  let giveUp = Date().addingTimeInterval(120)
  Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
    var lines = logTail(path)
    let caughtUp = (lines.last?.at ?? 0) >= to
    guard caughtUp || Date() > giveUp else { return }
    timer.invalidate()
    if (lines.first?.at ?? 0) > from { lines = logTail(path + ".1") + lines }  // rotated meanwhile
    let window = lines.filter { $0.at >= from && $0.at <= to }
    let heard = window.first { $0.text.contains("globalShortcut:nextWindowShortcut") && $0.text.contains("state:down") }
    let summoned = window.first { $0.text.contains("showUiOrCycleSelection()") }
    var cancelled = false
    if let summoned {
      let hide = window.first { $0.at >= summoned.at && $0.text.contains("beginHideUi()") }
      let focus = window.first { $0.at >= summoned.at && $0.text.contains("focusTarget()") }
      if let hide { cancelled = focus.map { $0.at > hide.at } ?? true }
    }
    let lastExpose = lines.last { $0.at <= to &&
      ($0.text.contains("missionControl observed") || $0.text.contains("missionControl announced")) }
    let noisy = ["AxObserverRegistry", "Thumbnail", "thumbnail", "screenshot"]
    let kept = window.filter { line in !noisy.contains { line.text.contains($0) } }.prefix(200).map { $0.text }
    var says = [heard == nil ? "never heard the hotkey" : "heard the hotkey"]
    if summoned != nil {
      says.append(cancelled ? "started a summon and cancelled it at once" : "summoned the switcher")
    } else if heard != nil {
      says.append("but never started a summon")
    }
    if let lastExpose {
      let reading = lastExpose.text.components(separatedBy: "missionControl ").last ?? ""
      says.append("last Exposé reading at \(lastExpose.text.prefix(12)): \(reading)")
    }
    if !caughtUp { says.append("(its log hadn't caught up after 2 min)") }
    record("alttab-log", [
      "episodeStarted": episodeStarted, "deadInEpisode": deadInEpisode, "caughtUp": caughtUp,
      "heardHotkey": heard != nil, "summoned": summoned != nil, "cancelledAtOnce": cancelled,
      "lastExposeReading": orNull(lastExpose?.text), "linesInWindow": window.count, "lines": Array(kept),
      "summary": "AltTab's own log: " + says.joined(separator: ", "),
    ])
  }
}

// MARK: - Holds: which app kept the key

// A filtering event tap holds every key until its callback returns, so one stalled app delays
// or kills ⌘⇥ for everyone. Each watched press is followed through the watcher's three taps:
// the HID tap (first of all), the session's first tap (once the HID filters let it go) and the
// session's last. One still on its way after 0.1 s gets every app with a filter ahead of the
// session's end asked, every 0.1 s, whether its main thread is free: their taps run there, and
// so do Accessibility requests, which a free main thread answers in a few milliseconds. The app
// that answers late or not at all, among the filters where the key waits, is the one holding it.

let heldAfter = 0.3           // a key this late at the session's end counts as held
let askTimeout: Float = 0.25
let busyAfter = 0.1           // a free main thread answers in 0.1–0.3 ms, once asked before (see warmUp)

// The watcher's own taps, by where they sit (made under "Taps and startup")
enum TapPlace: Int {
  case hid = 1, sessionHead, sessionTail
  var name: String {
    switch self {
    case .hid: return "hid"
    case .sessionHead: return "session head"
    case .sessionTail: return "session end"
    }
  }
}
struct OwnTap { let port: CFMachPort; let source: CFRunLoopSource }
var taps: [TapPlace: OwnTap] = [:]

// One watched press on its way, matched at each tap by the timestamp the event carries
final class Transit {
  let stamp: CGEventTimestamp
  var hidAt: TimeInterval?
  var sessionHeadAt: TimeInterval?
  var arrivedAt: TimeInterval?   // at the session's end
  var restamped = false          // came on with a new timestamp, matched by order
  var askedFrom: TimeInterval?
  var asked: [pid_t: Asked] = [:]
  var verdict: String?           // its gesture's, once judged: "dead", "worked" or "cut short"
  init(_ stamp: CGEventTimestamp) { self.stamp = stamp }
  func waited(_ now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
    guard let start = hidAt else { return 0 }
    return (arrivedAt ?? now) - start
  }
}

// One app with a filter ahead of the session's end, and how it answered while the key waited
final class Asked {
  let name: String
  var points: Set<String>
  var quick = 0, busy = 0, unaskable = 0
  var busyFrom: TimeInterval?, busyTo: TimeInterval?
  init(_ name: String, _ point: String) { self.name = name; points = [point] }
  var busyFor: TimeInterval { busyFrom.flatMap { from in busyTo.map { $0 - from } } ?? 0 }
}

var transits: [Transit] = []  // the latest few, newest last

// The press a sighting belongs to: the one with its timestamp. A filter that holds a key past
// its turn hands on a copy with a new timestamp (a test tap holding F20 1.5 s, 2026-10-09), so
// failing that, by order: the oldest press from the last 10 s not yet seen at this tap. Made
// here when the HID tap's sighting hasn't been handled yet.
func transit(for s: Seen, create: Bool) -> Transit? {
  if let t = transits.last(where: { $0.stamp == s.stamp }) { return t }
  if s.place != .hid, let t = transits.first(where: { t in
    guard let start = t.hidAt, s.at - start < 10, t.stamp < s.stamp else { return false }
    return s.place == .sessionHead ? t.sessionHeadAt == nil : t.arrivedAt == nil
  }) {
    t.restamped = true
    return t
  }
  guard create else { return nil }
  let t = Transit(s.stamp)
  transits.append(t)
  if transits.count > 20 { transits.removeFirst() }
  return t
}

func ask(_ pid: pid_t) -> (start: TimeInterval, end: TimeInterval, error: AXError) {
  let app = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(app, askTimeout)
  var value: CFTypeRef?
  let start = ProcessInfo.processInfo.systemUptime
  let error = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &value)
  return (start, ProcessInfo.processInfo.systemUptime, error)
}

// The first question to an app takes 17–66 ms (measured 2026-10-09, all six filter apps),
// which would read as busy; so each is asked once whenever the watcher's taps are made
func warmUp() {
  for pid in Set(filtersAhead().map { $0.tappingProcess }) {
    DispatchQueue.global(qos: .utility).async { _ = ask(pid) }
  }
}

func startAsking(_ t: Transit) {
  guard t.arrivedAt == nil, t.askedFrom == nil else { return }
  t.askedFrom = ProcessInfo.processInfo.systemUptime
  for tap in filtersAhead() {
    if let a = t.asked[tap.tappingProcess] {
      a.points.insert(pointName(tap))
    } else {
      t.asked[tap.tappingProcess] = Asked(processName(tap.tappingProcess), pointName(tap))
    }
  }
  askRound(t)
}

// Every app at once, off the main thread; again 0.1 s after the round, until the key gets
// through or 4 s have passed
func askRound(_ t: Transit) {
  let group = DispatchGroup()
  let lock = NSLock()
  var answers: [(pid: pid_t, start: TimeInterval, end: TimeInterval, error: AXError)] = []
  for pid in t.asked.keys {
    DispatchQueue.global(qos: .userInitiated).async(group: group) {
      let a = ask(pid)
      lock.lock()
      answers.append((pid, a.start, a.end, a.error))
      lock.unlock()
    }
  }
  group.notify(queue: .main) {
    for a in answers {
      guard let app = t.asked[a.pid] else { continue }
      if a.end - a.start >= busyAfter {
        app.busy += 1
        app.busyFrom = app.busyFrom ?? a.start
        app.busyTo = a.end
      } else if a.error == .success {
        app.quick += 1
      } else {
        app.unaskable += 1  // no Accessibility in it
      }
    }
    if t.arrivedAt == nil, t.waited() < 4 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { askRound(t) }
    }
  }
}

struct Hold {
  let waited: TimeInterval
  let arrived: Bool
  let segment: String?  // "hid" or "session": the filters the key waited in, as the session's first tap tells
  let named: [Asked]    // who held it
  let inferred: Bool    // named as the one app there that couldn't be asked, every other answering
  let cleared: [Asked]  // answered at once every time
  let fields: [String: Any]
}

func seconds(_ t: TimeInterval) -> String { String(format: "%.1f s", t) }

func analyze(_ t: Transit) -> Hold {
  let now = ProcessInfo.processInfo.systemUptime
  var segment: String?
  if taps[.sessionHead] != nil, let start = t.hidAt {
    if let head = t.sessionHeadAt {
      segment = head - start >= (t.arrivedAt ?? now) - head ? "hid" : "session"
    } else {
      segment = "hid"
    }
  }
  let all = t.asked.values.sorted { $0.name < $1.name }
  let here = all.filter { a in segment.map { a.points.contains($0) } ?? true }
  var named = here.filter { $0.busy > 0 }.sorted { $0.busyFor > $1.busyFor }
  var inferred = false
  if named.isEmpty {
    let unanswered = here.filter { $0.quick == 0 }
    if unanswered.count == 1 {
      named = unanswered
      inferred = true
    }
  }
  let cleared = here.filter { $0.busy == 0 && $0.quick > 0 }
  var fields: [String: Any] = [
    "waitedMs": Int(t.waited(now) * 1000), "arrived": t.arrivedAt != nil, "segment": orNull(segment),
    "named": named.map { $0.name }, "inferred": inferred, "restamped": t.restamped,
  ]
  if let start = t.hidAt {
    fields["sessionHeadMs"] = orNull(t.sessionHeadAt.map { Int(($0 - start) * 1000) })
    fields["askedAfterMs"] = orNull(t.askedFrom.map { Int(($0 - start) * 1000) })
  }
  fields["asked"] = all.map { a -> [String: Any] in
    ["process": a.name, "points": a.points.sorted(), "quick": a.quick, "busy": a.busy,
     "busyMs": Int(a.busyFor * 1000), "unaskable": a.unaskable]
  }
  return Hold(waited: t.waited(now), arrived: t.arrivedAt != nil, segment: segment, named: named,
              inferred: inferred, cleared: cleared, fields: fields)
}

// The gesture's first press whose key waited, if any
func hold(_ g: Gesture) -> Hold? {
  g.transits.first { $0.waited() >= heldAfter }.map(analyze)
}

func heldWords(_ h: Hold) -> (detail: String, alert: String) {
  let place = ["hid": "in the HID taps", "session": "in the session taps"][h.segment ?? ""] ?? "in the taps"
  let waited = h.arrived ? "waited \(seconds(h.waited)) \(place)" : "was still waiting \(place) after \(seconds(h.waited))"
  let cleared = h.cleared.map { $0.name }
  let others = cleared.isEmpty ? "" : "; the other apps there answered at once (\(cleared.joined(separator: ", ")))"
  if h.named.count == 1, let who = h.named.first {
    let why = h.inferred ? "it is the one app there that couldn't be asked\(others)"
                         : "its main thread was stuck for \(seconds(who.busyFor))\(others)"
    return ("\(who.name) held the key: it \(waited), and \(why)", "\(who.name) held the key \(seconds(h.waited))")
  }
  if h.named.count > 1 {
    let list = h.named.map { "\($0.name) \(seconds($0.busyFor))" }.joined(separator: ", ")
    return ("the key \(waited), and more than one app there was stuck: \(list)",
            "held by \(h.named.map { $0.name }.joined(separator: " or "))")
  }
  let asked = cleared.isEmpty ? "" : " (\(cleared.joined(separator: ", ")))"
  return ("the key \(waited), but every app with a filter there answered at once\(asked): a background thread in one of them, or the window server",
          "the key waited \(seconds(h.waited)) \(place)")
}

// MARK: - Watching presses

// One hold of ⌘ with one or more ⇥ in it
final class Gesture {
  let started: TimeInterval
  let front: Front
  let atPress: Overlay  // what AltTab's Exposé check read when the key went down
  let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName
  var hidTabs = 0, sessionTabs = 0
  var hidFlags: CGEventFlags?, sessionFlags: CGEventFlags?
  var strippedTabs = 0  // ⇥ that reached the session without the ⌘ the HID tap saw
  var strippedFlags: CGEventFlags?
  var releasedAt: TimeInterval?
  var transits: [Transit] = []
  init(_ windows: [WindowInfo], at: TimeInterval) {
    started = at
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

var gesture: Gesture?
var gestureTimer: Timer?
var episode: Episode?
var okPresses = 0, deadPresses = 0, cutShort = 0, latePresses = 0

// at: when the tap saw it, which a busy main thread doesn't change
func tabPressed(atHID: Bool, flags: CGEventFlags, at: TimeInterval) {
  // ⇥ after ⌘ came up is the next gesture (⌘⇥ ⌘⇥ to flip back and forth). Judged now,
  // the last one is proven only by a change already visible; without one it isn't judged
  // at all, since a dead ⌘⇥ pressed again and again still gets its last press judged.
  if let g = gesture, g.releasedAt != nil {
    if let how = proof(g, onScreenWindows()) {
      conclude(g, worked: how)
    } else {
      endGesture("cut short")
      cutShort += 1
    }
  }
  if gesture == nil {
    // ⌘⇧⇥ only means something once the switcher is up
    guard !flags.contains(.maskShift), isTest || running(altTabBundle) != nil else { return }
    gesture = Gesture(onScreenWindows(), at: at)
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

// ⌘ coming up, from the session's last tap, so a quick ⌘⇥ ⌘⇥ isn't read as one long hold
func flagsChanged(_ flags: CGEventFlags, at: TimeInterval) {
  if let g = gesture, g.releasedAt == nil, !flags.contains(.maskCommand) {
    g.releasedAt = at
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

// Its presses keep the verdict: a key that comes through after it starts no gesture of its own
func endGesture(_ verdict: String) {
  for t in gesture?.transits ?? [] where t.verdict == nil { t.verdict = verdict }
  gestureTimer?.invalidate()
  gestureTimer = nil
  gesture = nil
}

func conclude(_ g: Gesture, worked how: String?, stillHeld: Bool = false) {
  endGesture(how == nil ? "dead" : "worked")
  if let how { pressWorked(g, how) } else { pressWasDead(g, stillHeld: stillHeld) }
}

// A key held up at the session's end after its press was judged dead
func cameThroughLate(_ t: Transit) {
  guard t.verdict == "dead", t.waited() >= heldAfter else { return }
  let h = analyze(t)
  record("held-arrived", ["hold": h.fields,
                          "summary": "the dead \(chord) came through \(seconds(h.waited)) late · \(heldWords(h).detail)"])
}

func pressWorked(_ g: Gesture, _ how: String) {
  okPresses += 1
  if isTest {
    record("worked", ["how": how, "frontBefore": orNull(g.frontApp),
                      "frontNow": orNull(NSWorkspace.shared.frontmostApplication?.localizedName)])
  }
  if let h = hold(g) {
    latePresses += 1
    record("late", ["hold": h.fields, "summary": "\(chord) worked, late · \(heldWords(h).detail)"])
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
  let hold: Hold?
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
  let unseen = taps[.hid] != nil && g.hidTabs > 0 && g.sessionTabs == 0
  if blocksAltTab(g.atPress.verdict) {
    return gestureSuspect(g.atPress, when: "as the key went down", unseen: unseen)
  }
  if unseen, g.strippedTabs > 0 {
    let arrived = modifiers(g.strippedFlags ?? [])
    return Suspect(code: "modifier",
                   detail: "⌘ was taken off the key between the HID tap and the session's end: it arrived as \(arrived == "none" ? "plain" : arrived) ⇥",
                   alert: "⌘ was stripped off the key before any app saw it")
  }
  // Still held when judged, or held a second or more: the app holding it is the cause. (A key
  // through sooner still reached AltTab with ⌘ on it; that is only noted.)
  if let hold = s.hold, !hold.arrived || hold.waited >= 1 {
    let words = heldWords(hold)
    return Suspect(code: "held", detail: words.detail, alert: words.alert)
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
  press["seenAtHID"] = taps[.hid] == nil ? NSNull() : NSNumber(value: g.hidTabs > 0)
  press["waitedMs"] = g.transits.map { Int($0.waited() * 1000) }  // from the HID tap to the session's end, per ⇥
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
  altTab["logging"] = orNull(s.altTab.map { altTabRunsWithLog($0.processIdentifier) })
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
  fields["hold"] = orNull(s.hold?.fields)
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
  let judgedAt = Date()
  let pressedAt = judgedAt.addingTimeInterval(g.started - ProcessInfo.processInfo.systemUptime)
  deadPresses += 1
  let e = episode ?? Episode()
  episode = e
  e.dead += 1
  let windows = onScreenWindows()
  let altTab = running(altTabBundle)
  let altTabWindows: [[String: Any]] = windows.filter { owner($0) == altTab?.processIdentifier }.map { describe($0) }
  let judged = Scene(gesture: g, stillHeld: stillHeld, seen: overlay(windows), altTab: altTab,
                     altTabWindows: altTabWindows, frontApp: NSWorkspace.shared.frontmostApplication,
                     modifiers: modifierState(), taps: tapCensus(), hold: hold(g), ax: nil, fullscreen: nil,
                     exception: nil)
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
      var late = ""
      if let h = scene.hold, suspect.code != "held" { late = " · its key came through late too: \(heldWords(h).detail)" }
      fields["summary"] = "dead \(chord) (\(place)) · \(suspect.detail)\(late)"
      record("dead", fields)
      if e.dead == 1, let altTabPid { sampleAltTab(altTabPid, episodeStarted: started) }
      excerptAltTabLog(pressedAt: pressedAt, judgedAt: judgedAt, episodeStarted: started, deadInEpisode: e.dead)
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
  let verdict = taps[.hid] != nil && hidKeyDowns == 0 ? "the HID tap saw none: a swallowed key can't be told apart" : "both taps see typing"
  record("taps-live", ["hidKeyDowns": hidKeyDowns, "sessionKeyDowns": sessionKeyDowns,
                       "summary": "first key-downs: HID \(hidKeyDowns), session \(sessionKeyDowns) · \(verdict)"])
}

// What a tap saw, noted on the tap thread and handled on main
struct Seen {
  let type: CGEventType
  let place: TapPlace
  let at: TimeInterval
  let flags: CGEventFlags
  let stamp: CGEventTimestamp
  let keycode: Int64
  let autorepeat: Bool
}

func handle(_ s: Seen) {
  if s.type == .flagsChanged {
    if s.place == .sessionTail { flagsChanged(s.flags, at: s.at) }
    return
  }
  if s.place == .hid { hidKeyDowns += 1 }
  if s.place == .sessionTail {
    sessionKeyDowns += 1
    if !tapsChecked, sessionKeyDowns >= 20 { checkTapsOnce() }
  }
  guard s.keycode == watchedKey, !s.autorepeat else { return }
  let command = s.flags.contains(.maskCommand)
  switch s.place {
  case .hid:
    guard command, let t = transit(for: s, create: true) else { return }
    t.hidAt = s.at
    tabPressed(atHID: true, flags: s.flags, at: s.at)
    guard let g = gesture else { return }  // AltTab not running, or ⌘⇧⇥ with no switcher up
    g.transits.append(t)
    // Not through by 0.1 s after the press: ask who is holding it
    let wait = max(0, s.at + 0.1 - ProcessInfo.processInfo.systemUptime)
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { startAsking(t) }
  case .sessionHead:
    transit(for: s, create: command)?.sessionHeadAt = s.at
  case .sessionTail:
    let t = transit(for: s, create: command)
    t?.arrivedAt = s.at
    // A press already judged dead, held until now: it starts no gesture of its own
    if let t, t.verdict != nil { return cameThroughLate(t) }
    if command {
      tabPressed(atHID: false, flags: s.flags, at: s.at)
    } else if let g = gesture, g.hidTabs > g.sessionTabs + g.strippedTabs {
      // The HID tap saw ⌘ on this ⇥, the session's end doesn't: a tap in between took ⌘ away
      g.strippedTabs += 1
      g.strippedFlags = g.strippedFlags ?? s.flags
    }
  }
}

func reenable(_ place: TapPlace, why: String) {
  // An enabled tap here means the call came from one seatTaps retired
  guard let tap = taps[place], !CGEvent.tapIsEnabled(tap: tap.port) else { return }
  CGEvent.tapEnable(tap: tap.port, enable: true)
  if Date().timeIntervalSince(lastReenableRecord) > 600 {
    lastReenableRecord = Date()
    record("tap-reenabled", ["tap": place.name, "why": why,
                             "summary": "macOS switched the \(place.name) tap off (\(why)); switched back on"])
  }
}

let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
  let at = ProcessInfo.processInfo.systemUptime
  let place = TapPlace(rawValue: Int(bitPattern: refcon)) ?? .sessionTail
  switch type {
  case .keyDown, .flagsChanged:
    let seen = Seen(type: type, place: place, at: at, flags: event.flags, stamp: event.timestamp,
                    keycode: event.getIntegerValueField(.keyboardEventKeycode),
                    autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    DispatchQueue.main.async { handle(seen) }
  case .tapDisabledByTimeout, .tapDisabledByUserInput:
    let why = type == .tapDisabledByTimeout ? "timeout" : "user input"
    DispatchQueue.main.async { reenable(place, why: why) }
  default:
    break
  }
  return Unmanaged.passUnretained(event)
}

// The taps run on a thread of their own, so a busy main thread (reading AltTab's log, listing
// windows) can't make a key look late: each callback notes the time and hands the rest to main
var tapLoop: CFRunLoop?
let tapLoopReady = DispatchSemaphore(value: 0)
let tapThread = Thread {
  tapLoop = CFRunLoopGetCurrent()
  // A timer that never fires keeps the loop running while it has no tap
  CFRunLoopAddTimer(tapLoop, CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }, .commonModes)
  tapLoopReady.signal()
  CFRunLoopRun()
}
tapThread.qualityOfService = .userInteractive
tapThread.start()
tapLoopReady.wait()

func makeTap(_ point: CGEventTapLocation, _ placement: CGEventTapPlacement, _ place: TapPlace) -> OwnTap? {
  guard let port = CGEvent.tapCreate(tap: point, place: placement, options: .listenOnly,
                                     eventsOfInterest: bit(.keyDown) | bit(.flagsChanged), callback: tapCallback,
                                     userInfo: UnsafeMutableRawPointer(bitPattern: place.rawValue)),
        let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return nil }
  CFRunLoopAddSource(tapLoop, source, .commonModes)
  CGEvent.tapEnable(tap: port, enable: true)
  CFRunLoopWakeUp(tapLoop)
  return OwnTap(port: port, source: source)
}

var seatedAmong: Set<UInt32> = []  // the other apps' filters ahead when ours were made
var filterApps: Set<String> = []   // every app seen with one, so only a newcomer is logged

// The HID tap sees a press first, the session's first tap once the HID filters let it go, its
// last after every other tap had its turn. A filter made later may sit ahead of the first two
// or behind the last, so then all three are made again: after an app's update or relaunch,
// and whenever stepper's mousemove.lua remakes its flags tap (after 10 s without its events).
func seatTaps() {
  for tap in taps.values {
    CFRunLoopRemoveSource(tapLoop, tap.source, .commonModes)
    CFMachPortInvalidate(tap.port)
  }
  taps = [:]
  taps[.hid] = makeTap(.cghidEventTap, .headInsertEventTap, .hid)
  taps[.sessionHead] = makeTap(.cgSessionEventTap, .headInsertEventTap, .sessionHead)
  taps[.sessionTail] = makeTap(.cgSessionEventTap, .tailAppendEventTap, .sessionTail)
  let filters = filtersAhead(enabledOnly: false)
  seatedAmong = Set(filters.map { $0.eventTapID })
  filterApps.formUnion(filters.map { processName($0.tappingProcess) })
  warmUp()
}

// Between gestures, from the 2 s poll
func reseatIfNeeded() {
  guard gesture == nil else { return }
  let filters = filtersAhead(enabledOnly: false)
  let added = filters.filter { !seatedAmong.contains($0.eventTapID) }
  guard !added.isEmpty else {
    seatedAmong = Set(filters.map { $0.eventTapID })  // gone ones don't move ours
    return
  }
  let newcomers = Set(added.map { processName($0.tappingProcess) }).subtracting(filterApps).sorted()
  seatTaps()
  if !newcomers.isEmpty {
    record("taps-reseated", ["new": newcomers,
                             "summary": "a key filter from \(newcomers.joined(separator: ", ")), new this run: the watcher's taps were made again, to stay first and last"])
  }
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

// A press seen by the HID tap and never by the session's end was swallowed in between
seatTaps()
guard taps[.hid] != nil || taps[.sessionTail] != nil else {
  record("error", ["summary": "no event tap could be created: Hammerspoon needs Accessibility (or Input Monitoring)"])
  exit(3)
}

let altTabAtStart = running(altTabBundle)
let tapNames = [TapPlace.hid, .sessionHead, .sessionTail].filter { taps[$0] != nil }.map { $0.name }.joined(separator: " + ")
let altTabLogging: Bool? = altTabAtStart.map { altTabRunsWithLog($0.processIdentifier) }
let loggingNote = altTabLogging == true ? "its own log on" : altTabLogging == false ? "its own log off" : "-"
record("start", [
  "pid": Int(getpid()), "replaced": orNull(replaced), "altTab": orNull(altTabAtStart.map(version)),
  "altTabLogging": orNull(altTabLogging), "altTabLog": orNull(altTabLogPath),
  "taps": tapNames, "listenAccess": CGPreflightListenEventAccess(), "axTrusted": AXIsProcessTrusted(),
  "displays": displayList(), "stageManager": stageManager(),
  "summary": "watching \(chord) for AltTab \(altTabAtStart.map(version) ?? "(not running)") (\(loggingNote)) · taps: \(tapNames) · Accessibility \(AXIsProcessTrusted() ? "yes" : "NO")",
])

DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                                    object: nil, queue: .main) { _ in lastUnlock = Date() }

Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
  pollOverlay()
  reseatIfNeeded()
}

// An hourly heartbeat while the keyboard is in use
Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
  guard sessionKeyDowns + hidKeyDowns > 0 else { return }
  record("tally", ["ok": okPresses, "late": latePresses, "dead": deadPresses, "cutShort": cutShort,
                   "hidKeyDowns": hidKeyDowns, "sessionKeyDowns": sessionKeyDowns,
                   "summary": "past hour: \(okPresses) \(chord) worked (\(latePresses) late), \(deadPresses) dead, \(cutShort) cut short by the next · key-downs seen: HID \(hidKeyDowns), session \(sessionKeyDowns)"])
  okPresses = 0
  latePresses = 0
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
