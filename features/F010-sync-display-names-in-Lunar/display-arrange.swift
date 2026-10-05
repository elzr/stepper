// display-arrange — rotate and place displays on Apple Silicon without Lunar.
//
// hs.screen:rotate() and displayplacer's degree: go through the IOFramebuffer
// probe path that DCP displays don't have, so they are no-ops here. System
// Settings (and Lunar) rotate through the private MonitorPanel.framework, whose
// MPDisplay objects wrap a CGDirectDisplayID. This tool builds a fresh
// MPDisplayMgr every run and addresses the display by its current ID, so it
// cannot be fooled by a cached object from before a hub re-enumeration (which
// is how Lunar's `displays <uuid> rotation N` came to report success while
// moving nothing on 2026-10-03 and 2026-10-04).
//
// Build:  swiftc -O -o display-arrange display-arrange.swift
// Usage:  display-arrange list
//         display-arrange rotate <displayID> <0|90|180|270>
//         display-arrange place <displayID>:<x>,<y> [<displayID>:<x>,<y> ...]
//
// Every command prints one JSON document and exits 0 on success, 1 on failure.
// `rotate` waits until CoreGraphics reports the new angle; `place` sets every
// origin in a single CGBeginDisplayConfiguration transaction (moving two
// displays onto each other's spots one at a time makes macOS nudge the first
// one away) and waits until the bounds have landed.

import CoreGraphics
import Foundation
import ObjectiveC

// MARK: - MonitorPanel bridging (selectors verified against macOS 27 with class_copyMethodList)

@objc protocol MPDisplayMgrProto {
    func displays() -> [AnyObject]
    func displayWithID(_ id: Int32) -> AnyObject?
    func tryLockAccess() -> Bool
    func unlockAccess()
    func notifyWillReconfigure()
    func notifyReconfigure()
}

@objc protocol MPDisplayProto {
    var displayID: Int32 { get }
    var orientation: Int32 { get set }
    var displayName: String { get }
    var uuid: NSUUID { get }
    func canChangeOrientation() -> Bool
}

let lockTries = 40          // tryLockAccess retries, 0.25 s apart (System Settings or Lunar may hold it)
let rotateTimeout = 12.0    // s to wait for CGDisplayRotation to report the new angle
let placeTimeout = 6.0      // s to wait for CGDisplayBounds to land
let originTolerance = 4.0   // px

func fail(_ message: String) -> Never {
    let out: [String: Any] = ["ok": false, "error": message]
    printJSON(out)
    exit(1)
}

func printJSON(_ value: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else {
        print("{\"ok\":false,\"error\":\"could not encode result\"}")
        return
    }
    print(text)
}

func loadMonitorPanel() -> MPDisplayMgrProto {
    let path = "/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel"
    guard dlopen(path, RTLD_NOW) != nil else {
        fail("dlopen MonitorPanel failed: \(String(cString: dlerror()))")
    }
    guard let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type else {
        fail("MPDisplayMgr class not found")
    }
    return unsafeBitCast(cls.init(), to: MPDisplayMgrProto.self)
}

func panel(_ object: AnyObject) -> MPDisplayProto {
    unsafeBitCast(object, to: MPDisplayProto.self)
}

func spin(_ seconds: Double) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

func describe(_ id: CGDirectDisplayID, _ mp: MPDisplayProto?) -> [String: Any] {
    let b = CGDisplayBounds(id)
    var row: [String: Any] = [
        "id": Int(id),
        "uuid": mp?.uuid.uuidString ?? "",
        "rotation": Int(CGDisplayRotation(id)),
        "x": Int(b.origin.x), "y": Int(b.origin.y),
        "w": Int(b.size.width), "h": Int(b.size.height),
        "main": CGDisplayIsMain(id) != 0,
    ]
    if let mp {
        row["name"] = mp.displayName
        row["canRotate"] = mp.canChangeOrientation()
        row["panelOrientation"] = Int(mp.orientation)
    }
    return row
}

func onlineDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

// MARK: - Commands

func list() {
    let mgr = loadMonitorPanel()
    var byID: [Int32: MPDisplayProto] = [:]
    for object in mgr.displays() {
        let mp = panel(object)
        byID[mp.displayID] = mp
    }
    let rows = onlineDisplayIDs().map { describe($0, byID[Int32($0)]) }
    printJSON(["ok": true, "displays": rows])
}

func rotate(idText: String, degreesText: String) {
    guard let idValue = Int32(idText), let degrees = Int32(degreesText),
          [0, 90, 180, 270].contains(degrees)
    else {
        fail("usage: rotate <displayID> <0|90|180|270>")
    }
    let id = CGDirectDisplayID(idValue)
    let before = Int(CGDisplayRotation(id))
    if before == Int(degrees) {
        printJSON(["ok": true, "id": Int(id), "rotation": before, "changed": false])
        return
    }
    let mgr = loadMonitorPanel()
    guard let object = mgr.displayWithID(idValue) else {
        fail("MonitorPanel has no display with id \(idValue)")
    }
    let mp = panel(object)
    guard mp.canChangeOrientation() else {
        fail("display \(idValue) (\(mp.displayName)) cannot change orientation")
    }
    var locked = false
    for _ in 0..<lockTries {
        if mgr.tryLockAccess() { locked = true; break }
        spin(0.25)
    }
    guard locked else { fail("could not lock MonitorPanel access (System Settings or Lunar holding it?)") }
    mgr.notifyWillReconfigure()
    mp.orientation = degrees
    mgr.notifyReconfigure()
    mgr.unlockAccess()

    let deadline = Date(timeIntervalSinceNow: rotateTimeout)
    var now = Int(CGDisplayRotation(id))
    while now != Int(degrees), Date() < deadline {
        spin(0.25)
        now = Int(CGDisplayRotation(id))
    }
    guard now == Int(degrees) else {
        fail("asked MonitorPanel for \(degrees) but CoreGraphics still reports \(now) after \(Int(rotateTimeout)) s (panel says \(mp.orientation))")
    }
    printJSON(["ok": true, "id": Int(id), "rotation": now, "changed": true, "from": before] as [String: Any])
}

func place(specs: [String]) {
    struct Spec { let id: CGDirectDisplayID; let x: Int32; let y: Int32 }
    var parsed: [Spec] = []
    for spec in specs {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { fail("bad spec '\(spec)', want <displayID>:<x>,<y>") }
        let xy = parts[1].split(separator: ",").map(String.init)
        guard let id = UInt32(parts[0]), xy.count == 2, let x = Int32(xy[0]), let y = Int32(xy[1]) else {
            fail("bad spec '\(spec)', want <displayID>:<x>,<y>")
        }
        parsed.append(Spec(id: CGDirectDisplayID(id), x: x, y: y))
    }
    guard !parsed.isEmpty else { fail("usage: place <displayID>:<x>,<y> ...") }
    let online = Set(onlineDisplayIDs())
    for spec in parsed where !online.contains(spec.id) {
        fail("display \(spec.id) is not online")
    }

    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
        fail("CGBeginDisplayConfiguration failed")
    }
    for spec in parsed {
        let err = CGConfigureDisplayOrigin(cfg, spec.id, spec.x, spec.y)
        guard err == .success else {
            CGCancelDisplayConfiguration(cfg)
            fail("CGConfigureDisplayOrigin(\(spec.id), \(spec.x), \(spec.y)) failed: \(err.rawValue)")
        }
    }
    let err = CGCompleteDisplayConfiguration(cfg, .permanently)
    guard err == .success else { fail("CGCompleteDisplayConfiguration failed: \(err.rawValue)") }

    func landed() -> Bool {
        parsed.allSatisfy { spec in
            let b = CGDisplayBounds(spec.id)
            return abs(b.origin.x - Double(spec.x)) <= originTolerance
                && abs(b.origin.y - Double(spec.y)) <= originTolerance
        }
    }
    let deadline = Date(timeIntervalSinceNow: placeTimeout)
    while !landed(), Date() < deadline { spin(0.25) }
    let rows = parsed.map { describe($0.id, nil) }
    if landed() {
        printJSON(["ok": true, "displays": rows])
    } else {
        printJSON(["ok": false, "error": "origins did not land within \(Int(placeTimeout)) s", "displays": rows])
        exit(1)
    }
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "list":
    list()
case "rotate" where args.count == 3:
    rotate(idText: args[1], degreesText: args[2])
case "place" where args.count >= 2:
    place(specs: Array(args.dropFirst()))
default:
    fail("usage: display-arrange list | rotate <displayID> <degrees> | place <displayID>:<x>,<y> ...")
}
