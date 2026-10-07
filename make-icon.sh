#!/bin/bash
# Renders the app icon from the SAME SF Symbol the menu bar uses, and writes
# Resources/AppIcon.icns.
#
# Run this only when the glyph changes; build.sh just copies the .icns, so an
# ordinary build needs neither swiftc-for-icons nor iconutil. The result is
# committed, because an app whose icon depends on a build step is an app that
# ships without one the first time that step fails.
set -euo pipefail
cd "$(dirname "$0")"

SYMBOL="${1:-waveform.path.ecg}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/icon.swift" <<'SWIFT'
import AppKit

// macOS icon geometry: the rounded square does NOT fill the canvas. Apple's
// grid leaves roughly a tenth of it as margin on each side and rounds the
// corners to about 22% of the square's own width -- get either wrong and the
// icon reads as subtly the wrong size next to every other one in the Dock.
let symbol = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

func render(_ px: Int) -> NSBitmapImageRep {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = s * 0.094
    let square = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let body = NSBezierPath(roundedRect: square,
                            xRadius: square.width * 0.2237, yRadius: square.width * 0.2237)
    body.addClip()
    // Graphite rather than a colour: this is a system utility that sits beside
    // Activity Monitor, and the two charts inside it already own green, blue
    // and orange. A tinted icon would claim one of them as the app's.
    NSGradient(starting: NSColor(calibratedWhite: 0.26, alpha: 1),
               ending: NSColor(calibratedWhite: 0.11, alpha: 1))!
        .draw(in: square, angle: -90)

    let glyphSide = square.width * 0.62
    let cfg = NSImage.SymbolConfiguration(pointSize: glyphSide, weight: .medium)
    if let g = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
        // The symbol arrives as a template, i.e. black, and has to be tinted in
        // a layer of its OWN. Filling sourceAtop straight onto the icon paints
        // every pixel with alpha -- and the gradient below is fully opaque, so
        // the whole glyph rectangle comes out as a white block. Ask how I know.
        let white = NSImage(size: g.size, flipped: false) { r in
            g.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        white.draw(in: NSRect(x: square.midX - g.size.width / 2,
                              y: square.midY - g.size.height / 2,
                              width: g.size.width, height: g.size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                   ("128x128", 128), ("128x128@2x", 256), ("256x256", 256),
                   ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let data = render(px).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(name).png"))
}
SWIFT

mkdir -p "$WORK/AppIcon.iconset"
swiftc -O -framework AppKit -o "$WORK/mkicon" "$WORK/icon.swift"
"$WORK/mkicon" "$SYMBOL" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns

echo "wrote Resources/AppIcon.icns from '$SYMBOL' ($(du -h Resources/AppIcon.icns | cut -f1))"
