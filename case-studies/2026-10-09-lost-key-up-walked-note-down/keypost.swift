// Presses one key from outside Hammerspoon, so the press can land while Hammerspoon's
// main thread is busy. Launch it through hs.task: Hammerspoon's Accessibility grant
// covers posting events. Each line it prints is "<seconds since start> <what>".
//
// Usage: keypost <keycode> <downAtMs> <upAtMs> [modifier keycode, e.g. 59 = left ctrl] [modifierUpAtMs]
// The modifier goes down 30 ms before the key and up 30 ms after it, unless modifierUpAtMs says otherwise.
// Build: swiftc -O -o keypost keypost.swift
import Foundation
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 4, let code = CGKeyCode(args[1]),
      let downAt = Double(args[2]), let upAt = Double(args[3]) else {
  print("usage: keypost <keycode> <downAtMs> <upAtMs> [modifier keycode]")
  exit(2)
}
let modCode: CGKeyCode? = args.count > 4 ? CGKeyCode(args[4]) : nil
let modFlags: [CGKeyCode: CGEventFlags] = [59: .maskControl, 56: .maskShift, 55: .maskCommand, 58: .maskAlternate]
let modFlag: CGEventFlags = modCode.flatMap { modFlags[$0] } ?? []

let source = CGEventSource(stateID: .hidSystemState)
let start = Date()

func wait(untilMs ms: Double) {
  let remaining = ms / 1000 - Date().timeIntervalSince(start)
  if remaining > 0 { usleep(useconds_t(remaining * 1_000_000)) }
}

func stamp(_ what: String) {
  print(String(format: "%.3f %@", Date().timeIntervalSince(start), what))
  fflush(stdout)
}

var modifierDown = false

func modifier(_ down: Bool) {
  guard let m = modCode, let e = CGEvent(keyboardEventSource: source, virtualKey: m, keyDown: down) else { return }
  e.type = .flagsChanged
  e.flags = down ? modFlag : []
  modifierDown = down
  e.post(tap: .cghidEventTap)
  stamp(down ? "modifier down" : "modifier up")
}

func key(_ down: Bool) {
  guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
  e.flags = modifierDown ? modFlag : []
  e.post(tap: .cghidEventTap)
  stamp(down ? "key down" : "key up")
}

let modUpAt = args.count > 5 ? Double(args[5]) ?? upAt + 30 : upAt + 30

// Every step in time order; ties keep this order
var steps: [(Double, () -> Void)] = [(downAt, { key(true) }), (upAt, { key(false) })]
if modCode != nil {
  steps.append((downAt - 30, { modifier(true) }))
  steps.append((modUpAt, { modifier(false) }))
}
let ordered = steps.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
for (_, (at, step)) in ordered {
  wait(untilMs: at)
  step()
}
