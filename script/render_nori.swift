// Rasterize the shared vector geometry for the existing macOS 13+ ICNS pipeline.
// Build with NoriGeometry.swift; no external image library is required.
import AppKit

@main
struct RenderNori {
    static func color(_ hex: UInt32) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [CGFloat((hex >> 16) & 255) / 255,
                             CGFloat((hex >> 8) & 255) / 255,
                             CGFloat(hex & 255) / 255, 1])!
    }

    static func mascot(_ context: CGContext, template: Bool = false) {
        context.setFillColor(template ? color(0) : color(NoriGeometry.body))
        context.addPath(NoriGeometry.bodyPath())
        context.fillPath()
        for eye in NoriGeometry.eyes {
            context.saveGState()
            context.translateBy(x: eye.x, y: eye.y)
            context.rotate(by: NoriGeometry.eyeTilt)
            if template { context.setBlendMode(.clear) }
            else { context.setFillColor(color(NoriGeometry.ink)) }
            let rect = CGRect(x: -NoriGeometry.eyeWidth / 2, y: -NoriGeometry.eyeHeight / 2,
                              width: NoriGeometry.eyeWidth, height: NoriGeometry.eyeHeight)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 9, cornerHeight: 9, transform: nil))
            context.fillPath()
            context.restoreGState()
        }
    }

    static func write(_ url: URL, pixels: Int, drawing: (CGContext) -> Void) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                bytesPerRow: pixels * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: 1, y: -1)
        drawing(context)
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: render_nori SUPPORT_DIRECTORY\n", stderr); exit(2)
        }
        let support = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try write(support.appendingPathComponent("AppIcon-1024.png"), pixels: 1024) { context in
            // Legacy ICNS: optical inset and pre-masked tile. Icon Composer uses
            // full-bleed unmasked layers instead (Support/Nori/AppIcon.icon).
            let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
            context.setFillColor(color(NoriGeometry.ink))
            context.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
            context.fillPath()
            context.translateBy(x: 174, y: 184)
            context.scaleBy(x: 2.61, y: 2.61)
            mascot(context)
        }
        for name in ["HeaderBrandIcon.png", "LogoTransparent.png"] {
            try write(support.appendingPathComponent(name), pixels: 256) { mascot($0) }
        }
        for (name, size) in [("MenuBarIconTemplate.png", 18), ("MenuBarIconTemplate@2x.png", 36)] {
            try write(support.appendingPathComponent(name), pixels: size) { context in
                context.scaleBy(x: CGFloat(size) / 256, y: CGFloat(size) / 256)
                mascot(context, template: true)
            }
        }
        print("Nori sRGB master, transparent header artwork and 18/36px template images rendered.")
    }
}
