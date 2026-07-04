#!/usr/bin/env swift
// Generates GhostWriter app icon at 1024×1024 PNG using CoreGraphics (no AppKit).
import CoreGraphics
import ImageIO
import Foundation

let outPath: String = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/gw_icon_1024.png"

let S: Int   = 1024
let SF: CGFloat = CGFloat(S)

let cs  = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: S, height: S,
    bitsPerComponent: 8, bytesPerRow: S * 4,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}
func radial(cx: CGFloat, cy: CGFloat, r: CGFloat, c0: CGColor, c1: CGColor) {
    let grad = CGGradient(colorsSpace: cs,
        colors: [c0, c1] as CFArray, locations: [0, 1] as [CGFloat])!
    ctx.saveGState()
    ctx.drawRadialGradient(grad,
        startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
        endCenter:   CGPoint(x: cx, y: cy), endRadius:   r,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
func fill(_ path: CGPath, _ color: CGColor) {
    ctx.saveGState(); ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath(); ctx.restoreGState()
}
func stroke(_ path: CGPath, _ color: CGColor, _ width: CGFloat, _ cap: CGLineCap = .butt) {
    ctx.saveGState(); ctx.addPath(path)
    ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.setLineCap(cap)
    ctx.strokePath(); ctx.restoreGState()
}

// ── Background ───────────────────────────────────────────────────────────────
ctx.setFillColor(rgba(0.043, 0.059, 0.102, 1))
ctx.fill(CGRect(x: 0, y: 0, width: SF, height: SF))

// Ambient glow — two nested radials: deep teal core fading to navy
radial(cx: SF*0.5, cy: SF*0.52, r: SF*0.50,
    c0: rgba(0.04, 0.50, 0.65, 0.30),
    c1: rgba(0.04, 0.50, 0.65, 0.0))

// ── Ghost geometry ── large, fills ~78% canvas height ────────────────────────
let cx_: CGFloat = SF * 0.5         // 512
let hCY: CGFloat = SF * 0.673       // head arc centre y ≈ 689
let hR:  CGFloat = SF * 0.225       // head radius ≈ 230  → head top ≈ 919
let wY:  CGFloat = SF * 0.228       // waist y ≈ 234
let bL  = cx_ - hR                  // ≈ 282
let bR  = cx_ + hR                  // ≈ 742
let seg = (bR - bL) / 3.0           // ≈ 153
let bpY = wY - SF * 0.110           // bump tip ≈ 122   → total span ≈ 797px

let gp = CGMutablePath()
gp.move(to:   CGPoint(x: bL, y: wY))
gp.addLine(to: CGPoint(x: bL, y: hCY))
gp.addArc(center: CGPoint(x: cx_, y: hCY),
    radius: hR, startAngle: .pi, endAngle: 0, clockwise: false)
gp.addLine(to: CGPoint(x: bR, y: wY))
// 3 bumps right→left
gp.addCurve(to: CGPoint(x: bR - seg, y: wY),
    control1: CGPoint(x: bR,        y: bpY),
    control2: CGPoint(x: bR - seg,  y: bpY))
gp.addCurve(to: CGPoint(x: bL + seg, y: wY),
    control1: CGPoint(x: bR - seg,   y: bpY),
    control2: CGPoint(x: bL + seg,   y: bpY))
gp.addCurve(to: CGPoint(x: bL, y: wY),
    control1: CGPoint(x: bL + seg, y: bpY),
    control2: CGPoint(x: bL,       y: bpY))
gp.closeSubpath()

// Ghost fill — luminous blue-white
fill(gp, rgba(0.908, 0.928, 0.960, 0.96))

// Subtle top highlight clipped to ghost shape
ctx.saveGState()
ctx.addPath(gp); ctx.clip()
radial(cx: cx_, cy: hCY + hR * 0.50, r: hR * 1.35,
    c0: rgba(1, 1, 1, 0.30),
    c1: rgba(1, 1, 1, 0.0))
// Bottom shadow inside ghost (slight darkening at bottom half)
radial(cx: cx_, cy: wY + SF*0.04, r: hR * 1.1,
    c0: rgba(0.5, 0.62, 0.78, 0.22),
    c1: rgba(0.5, 0.62, 0.78, 0.0))
ctx.restoreGState()

// Thin cyan rim on ghost silhouette
stroke(gp, rgba(0.18, 0.72, 0.88, 0.50), SF * 0.006)

// ── Eyes ─────────────────────────────────────────────────────────────────────
let eY   = hCY + hR * 0.10    // ≈ 712
let eXO  = hR  * 0.355        // ≈ 82
let eR   = hR  * 0.128        // ≈ 29

for sign: CGFloat in [-1, 1] {
    let ex = cx_ + sign * eXO

    // Layered glow: wide soft halo then bright core
    radial(cx: ex, cy: eY, r: eR * 4.2,
        c0: rgba(0.06, 0.76, 0.92, 0.35),
        c1: rgba(0.06, 0.76, 0.92, 0.0))
    radial(cx: ex, cy: eY, r: eR * 2.0,
        c0: rgba(0.06, 0.76, 0.92, 0.60),
        c1: rgba(0.06, 0.76, 0.92, 0.0))

    // Dark iris
    let iris = CGPath(ellipseIn: CGRect(x: ex-eR, y: eY-eR, width: eR*2, height: eR*2), transform: nil)
    fill(iris, rgba(0.036, 0.052, 0.110, 1.0))

    // Specular highlight
    let sp = eR * 0.48
    let hl = CGPath(ellipseIn: CGRect(x: ex+eR*0.15, y: eY+eR*0.18, width: sp, height: sp), transform: nil)
    fill(hl, rgba(1, 1, 1, 0.82))
}

// ── Subtle expression: small open "O" mouth ──────────────────────────────────
// Keeps the ghost expressive; communicates "speaking"
let mY  = hCY - hR * 0.28     // ≈ 624 (below eyes)
let mR  = hR  * 0.07           // ≈ 16

// Mouth glow
radial(cx: cx_, cy: mY, r: mR * 3.2,
    c0: rgba(0.06, 0.76, 0.92, 0.25),
    c1: rgba(0.06, 0.76, 0.92, 0.0))

// Mouth ring
let mouth = CGPath(ellipseIn: CGRect(x: cx_-mR, y: mY-mR*0.7, width: mR*2, height: mR*1.4), transform: nil)
fill(mouth, rgba(0.036, 0.052, 0.110, 0.90))
// Inner highlight for depth
let mInner = mR * 0.50
let mi = CGPath(ellipseIn: CGRect(x: cx_-mInner, y: mY-mInner*0.55, width: mInner*2, height: mInner*1.1), transform: nil)
fill(mi, rgba(0.08, 0.20, 0.35, 0.70))

// ── Save PNG ─────────────────────────────────────────────────────────────────
guard let cgImg = ctx.makeImage() else { print("❌ makeImage failed"); exit(1) }
let url  = URL(fileURLWithPath: outPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
    print("❌ dest failed"); exit(1)
}
CGImageDestinationAddImage(dest, cgImg, nil)
guard CGImageDestinationFinalize(dest) else { print("❌ write failed"); exit(1) }
print("✅ \(outPath)")
