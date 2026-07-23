#!/usr/bin/env swift
// Рисует иконку и собирает AppIcon.icns.
//
// Мотив тот же, что в панели: тёмная плитка и блочные гейджи разной заливки.
// Никаких внешних инструментов, всё через CoreGraphics.
//
//   swift make-icon.swift && ./make-app.sh release install

import AppKit

let out = "Resources"
let iconset = "\(out)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

/// Три полоски с разной заливкой: 5h, неделя, скоуп. Верхняя акцентная.
let bars: [(fill: CGFloat, color: NSColor)] = [
    (0.72, NSColor(red: 0.37, green: 0.91, blue: 0.82, alpha: 1)),   // циан
    (0.46, NSColor(white: 1, alpha: 0.62)),
    (0.24, NSColor(white: 1, alpha: 0.34)),
]

func draw(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Поля по краям: макось сама не обрезает, отступ делаем руками.
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    // Радиус как у системных иконок, примерно 22% стороны.
    let plate = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237,
                             yRadius: rect.width * 0.2237)

    ctx.saveGState()
    plate.addClip()
    let gradient = NSGradient(colors: [NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1),
                                       NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)])!
    gradient.draw(in: rect, angle: -90)
    ctx.restoreGState()

    // Тонкая светлая кромка, чтоб плитка не сливалась с тёмными обоями.
    NSColor(white: 1, alpha: 0.10).setStroke()
    plate.lineWidth = max(1, s * 0.006)
    plate.stroke()

    // Полоски
    let trackX = rect.minX + rect.width * 0.185
    let trackW = rect.width * 0.63
    let barH = rect.height * 0.105
    let gap = rect.height * 0.105
    let block = CGFloat(bars.count) * barH + CGFloat(bars.count - 1) * gap
    var y = rect.midY + block / 2 - barH

    for bar in bars {
        let track = NSBezierPath(roundedRect: CGRect(x: trackX, y: y, width: trackW, height: barH),
                                 xRadius: barH / 2, yRadius: barH / 2)
        NSColor(white: 1, alpha: 0.11).setFill()
        track.fill()

        let fillW = max(barH, trackW * bar.fill)
        let fill = NSBezierPath(roundedRect: CGRect(x: trackX, y: y, width: fillW, height: barH),
                                xRadius: barH / 2, yRadius: barH / 2)
        bar.color.setFill()
        fill.fill()

        y -= barH + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// Набор размеров, который ждёт iconutil.
let wanted: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in wanted {
    let data = draw(size: px).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", "\(out)/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil не справился") }

try? FileManager.default.removeItem(atPath: iconset)
print("готово: \(out)/AppIcon.icns")
