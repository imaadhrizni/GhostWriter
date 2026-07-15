import SwiftUI
import AppKit

// MARK: - SwiftUI blocks → paginated PDF
//
// Renders a document as an ordered list of *blocks* and packs whole blocks onto
// US-Letter pages, so a chart, table, card, or criterion row is never split
// across a page boundary. (Slicing one tall raster can't work: Swift Charts
// paints its plot interior white, so gaps between bars look identical to real
// between-element gaps — any block would risk being cut mid-content.)
//
// A block taller than a full page is the only thing that gets sliced, and then
// the cut is nudged to a blank scanline band so text lines aren't bisected.
// Orientation is kept correct via `NSImage.draw(in:from:)` in a bottom-left
// `NSGraphicsContext` (a raw CGImage in a Quartz PDF context renders mirrored).

@MainActor
enum ViewPDF {

    /// Paginate `blocks` (top-down document order) into PDF data, or nil if
    /// nothing rendered. Each block is laid out at the page content width.
    static func data(blocks: [AnyView],
                     pageW: CGFloat = 612, pageH: CGFloat = 792,
                     margin: CGFloat = 44, scale: CGFloat = 2, spacing: CGFloat = 12) -> Data? {
        let contentW = pageW - margin * 2
        let usableH = pageH - margin * 2

        // Rasterise every block once.
        var images: [NSImage] = []
        for b in blocks {
            let wrapped = b
                .frame(width: contentW, alignment: .leading)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let r = ImageRenderer(content: wrapped)
            r.proposedSize = ProposedViewSize(width: contentW, height: nil)
            r.scale = scale
            if let img = r.nsImage, img.size.height > 0 { images.append(img) }
        }
        guard !images.isEmpty else { return nil }

        // One draw op = an image (or a slice of one) placed at a top offset on a page.
        struct Op { let img: NSImage; let src: NSRect; let destTop: CGFloat; let h: CGFloat }
        var pages: [[Op]] = []
        var cur: [Op] = []
        var y: CGFloat = 0
        func flush() { if !cur.isEmpty { pages.append(cur); cur = []; y = 0 } }

        for img in images {
            let hb = img.size.height
            let full = NSRect(x: 0, y: 0, width: img.size.width, height: hb)
            if hb <= usableH {
                // Whole block: start a fresh page if it won't fit in what's left.
                if y > 0, y + hb > usableH + 0.5 { flush() }
                cur.append(Op(img: img, src: full, destTop: y, h: hb))
                y += hb + spacing
            } else {
                // Block taller than a page: give it its own pages and slice it,
                // snapping cuts to blank bands so text rows stay intact.
                flush()
                let blank = blankRows(img)
                var top: CGFloat = 0
                while top < hb - 0.5 {
                    var sh = min(usableH, hb - top)
                    if hb - top > usableH, let b = blank,
                       let cut = rowGapCut(b, ideal: top + usableH, floor: top + usableH * 0.55) {
                        sh = cut - top
                    }
                    let src = NSRect(x: 0, y: hb - top - sh, width: img.size.width, height: sh)
                    pages.append([Op(img: img, src: src, destTop: 0, h: sh)])
                    top += sh
                }
            }
        }
        flush()
        guard !pages.isEmpty else { return nil }

        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let consumer = CGDataConsumer(data: pdf as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for page in pages {
            ctx.beginPDFPage(nil)
            let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsctx
            for op in page {
                let dest = NSRect(x: margin, y: pageH - margin - op.destTop - op.h,
                                  width: contentW, height: op.h)
                op.img.draw(in: dest, from: op.src, operation: .copy, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return pdf.length > 0 ? (pdf as Data) : nil
    }

    /// Convenience for a single monolithic view (rare — prefer blocks). Wraps it
    /// as one block, which means it will be sliced if taller than a page.
    static func data<V: View>(_ view: V, pageW: CGFloat = 612, pageH: CGFloat = 792,
                              margin: CGFloat = 44, scale: CGFloat = 2) -> Data? {
        data(blocks: [AnyView(view)], pageW: pageW, pageH: pageH, margin: margin, scale: scale)
    }

    // MARK: Blank-row analysis (only for a too-tall block being sliced)

    private static func blankRows(_ image: NSImage) -> (flags: [Bool], scale: CGFloat)? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard image.size.height > 0,
              let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        let bytesPerRow = w * 4
        var buf = [UInt8](repeating: 0, count: h * bytesPerRow)
        guard let bctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var flags = [Bool](repeating: false, count: h)
        let step = max(1, w / 200)
        for rowFromTop in 0..<h {
            let base = (h - 1 - rowFromTop) * bytesPerRow
            var white = true, x = 0
            while x < w {
                let i = base + x * 4
                if buf[i] < 250 || buf[i + 1] < 250 || buf[i + 2] < 250 { white = false; break }
                x += step
            }
            flags[rowFromTop] = white
        }
        return (flags, CGFloat(h) / image.size.height)
    }

    /// Scanning up from `ideal` to `floor` (top-down points), return the centre
    /// of the first blank band tall enough (≥10pt, bridging thin dividers) to be
    /// a gap between rows — not the thin leading inside a wrapped paragraph.
    private static func rowGapCut(_ b: (flags: [Bool], scale: CGFloat),
                                  ideal: CGFloat, floor: CGFloat) -> CGFloat? {
        let n = b.flags.count, scale = b.scale
        let minRun = Int((10.0 * scale).rounded())
        let bridge = Int((3.0 * scale).rounded())
        var r = min(n - 1, Int(ideal * scale))
        let stop = max(0, Int(floor * scale))
        while r > stop {
            guard b.flags[r] else { r -= 1; continue }
            var top = r, gap = 0, rr = r
            while rr > 0 { rr -= 1; if b.flags[rr] { top = rr; gap = 0 } else { gap += 1; if gap > bridge { break } } }
            var bot = r; gap = 0; rr = r
            while rr < n - 1 { rr += 1; if b.flags[rr] { bot = rr; gap = 0 } else { gap += 1; if gap > bridge { break } } }
            if bot - top >= minRun { return CGFloat((top + bot) / 2) / scale }
            r = top - 1
        }
        return nil
    }
}
