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

/// Тот же вырезанный кот, что на борде: иконку узнают по нему, а не по
/// абстрактным полоскам.
let cat = NSImage(contentsOfFile: "Resources/cat.png")

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

    // Кот по центру плитки. Вписываем по высоте: морда с ушами вытянута
    // вверх, по ширине упёрлись бы раньше и он стал бы мелким.
    if let cat {
        let target = rect.height * 0.78
        let scale = target / cat.size.height
        let width = cat.size.width * scale
        let box = CGRect(x: rect.midX - width / 2,
                         y: rect.midY - target / 2 - rect.height * 0.01,
                         width: width, height: target)
        ctx.saveGState()
        plate.addClip()
        cat.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
        ctx.restoreGState()
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
