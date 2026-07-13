#!/bin/bash
# Regenerate the GhostWriter app icon from its vector source.
#
# Renders a 1024px master with AppKit/CoreGraphics (no external rasterizer),
# fills the standard GhostWriter.iconset/ ladder with sips, and compiles
# GhostWriter.icns with iconutil. Run from the repo root:
#   ./make-appicon.sh
#
# Design: WSO2 navy (#1B2A4A) ground with a white "pen from sound" mark — a
# pen nib writing a waveform. Matches WSO2's white-on-navy visual identity
# (orange stays an accent) without reproducing the WSO2 logo.
set -euo pipefail
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
SWIFT="$TMP/makeicon.swift"
MASTER="$TMP/icon_1024.png"

cat > "$SWIFT" <<'SWIFTEOF'
import AppKit
let S = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let inset = 100.0, side = S - 2 * inset
let rect = CGRect(x: inset, y: inset, width: side, height: side)
let radius = side * 0.2237
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.clip()
// Flat WSO2 navy #1B2A4A so the punched-out nib slit/hole match exactly.
let navy = NSColor(srgbRed: 0.106, green: 0.165, blue: 0.290, alpha: 1.0)
navy.setFill()
CGRect(x: 0, y: 0, width: S, height: S).fill()
ctx.restoreGState()

// Pen nib (white triangle pointing down) with a navy slit + vent hole.
let nib = NSBezierPath()
nib.move(to: CGPoint(x: 437, y: 630))
nib.line(to: CGPoint(x: 587, y: 630))
nib.line(to: CGPoint(x: 512, y: 450))
nib.close()
NSColor.white.setFill()
nib.fill()
navy.setFill()
NSBezierPath(rect: CGRect(x: 504, y: 548, width: 16, height: 82)).fill()
NSBezierPath(ovalIn: CGRect(x: 497, y: 525, width: 30, height: 30)).fill()

// The waveform the nib is writing, just below the tip.
let wave = NSBezierPath()
wave.lineWidth = 34
wave.lineCapStyle = .round
wave.lineJoinStyle = .round
wave.move(to: CGPoint(x: 418, y: 400))
wave.curve(to: CGPoint(x: 474, y: 400), controlPoint1: CGPoint(x: 438, y: 440), controlPoint2: CGPoint(x: 458, y: 440))
wave.curve(to: CGPoint(x: 530, y: 400), controlPoint1: CGPoint(x: 494, y: 360), controlPoint2: CGPoint(x: 512, y: 360))
wave.curve(to: CGPoint(x: 606, y: 402), controlPoint1: CGPoint(x: 560, y: 440), controlPoint2: CGPoint(x: 588, y: 434))
NSColor.white.setStroke()
wave.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFTEOF

swift "$SWIFT" "$MASTER"

mkdir -p GhostWriter.iconset
sz() { sips -z "$1" "$1" "$MASTER" --out "GhostWriter.iconset/$2" >/dev/null; }
sz 16   icon_16x16.png
sz 32   icon_16x16@2x.png
sz 32   icon_32x32.png
sz 64   icon_32x32@2x.png
sz 64   icon_64x64.png
sz 128  icon_128x128.png
sz 256  icon_128x128@2x.png
sz 256  icon_256x256.png
sz 512  icon_256x256@2x.png
sz 512  icon_512x512.png
sz 1024 icon_512x512@2x.png
cp "$MASTER" GhostWriter.iconset/icon_1024x1024.png

iconutil -c icns GhostWriter.iconset -o GhostWriter.icns
rm -rf "$TMP"
echo "✅ Rebuilt GhostWriter.iconset + GhostWriter.icns (WSO2 navy · pen from sound)"
