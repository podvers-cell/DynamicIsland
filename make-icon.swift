// Draws the app icon. Run: swift make-icon.swift  ->  AppIcon.icns
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// Background: macOS-style rounded square (824pt body inside 1024 canvas) with a dark gradient
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.30, alpha: 1),
           ending: NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.09, alpha: 1))!.draw(in: bg, angle: -90)

// The island pill hanging from the top
let pill = NSRect(x: 212, y: 560, width: 600, height: 200)
NSColor.black.setFill()
NSBezierPath(roundedRect: pill, xRadius: 100, yRadius: 100).fill()

// Album art square on the left
NSGradient(starting: NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.45, alpha: 1),
           ending: NSColor(calibratedRed: 0.55, green: 0.30, blue: 1.0, alpha: 1))!
    .draw(in: NSBezierPath(roundedRect: NSRect(x: 262, y: 600, width: 120, height: 120), xRadius: 30, yRadius: 30), angle: -45)

// Green audio bars on the right
let green = NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.40, alpha: 1)
green.setFill()
for (i, h) in [60.0, 110, 80, 130, 70].enumerated() {
    let x = 560 + CGFloat(i) * 42
    NSBezierPath(roundedRect: NSRect(x: x, y: 660 - h / 2, width: 24, height: h), xRadius: 12, yRadius: 12).fill()
}

// Progress line under the island
NSColor(white: 1, alpha: 0.18).setFill()
NSBezierPath(roundedRect: NSRect(x: 262, y: 300, width: 500, height: 22), xRadius: 11, yRadius: 11).fill()
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 262, y: 300, width: 300, height: 22), xRadius: 11, yRadius: 11).fill()

img.unlockFocus()

let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
let set = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
let master = set.appendingPathComponent("master.png")
try! png.write(to: master)

for s in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(s)x\(s)\(scale == 2 ? "@2x" : "").png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-z", "\(s * scale)", "\(s * scale)", master.path, "--out", set.appendingPathComponent(name).path]
        p.standardOutput = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
    }
}
try! FileManager.default.removeItem(at: master)

let ic = Process()
ic.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
ic.arguments = ["-c", "icns", set.path, "-o", "AppIcon.icns"]
try! ic.run(); ic.waitUntilExit()
try! FileManager.default.removeItem(at: set)
print("Wrote AppIcon.icns")
