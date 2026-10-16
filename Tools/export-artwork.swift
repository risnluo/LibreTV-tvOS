import AppKit
import Foundation

// Export the original generated emblem at Apple's required asset sizes without changing its artwork.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Artwork/LibreTV-symbol-source.png")
guard let source = NSImage(contentsOf: sourceURL),
      let sourceRep = NSBitmapImageRep(data: try Data(contentsOf: sourceURL)), sourceRep.hasAlpha else {
    fatalError("The transparent source emblem is missing or invalid.")
}
let catalog = root.appendingPathComponent("App/Assets.xcassets")
let info: [String: Any] = ["author": "xcode", "version": 1]

func json(_ value: [String: Any], at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

enum Layer { case background, foreground, composite }

func png(_ url: URL, width: Int, height: Int, layer: Layer) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create artwork canvas") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let canvas = NSRect(x: 0, y: 0, width: width, height: height)
    NSColor.clear.setFill()
    canvas.fill(using: .copy)
    if layer != .foreground {
        NSGradient(starting: NSColor(srgbRed: 0.035, green: 0.075, blue: 0.13, alpha: 1),
                   ending: NSColor(srgbRed: 0.08, green: 0.16, blue: 0.24, alpha: 1))!.draw(in: canvas, angle: 35)
    }
    if layer != .background {
        let scale = min(CGFloat(width) / CGFloat(sourceRep.pixelsWide),
                        CGFloat(height) / CGFloat(sourceRep.pixelsHigh))
        let size = NSSize(width: CGFloat(sourceRep.pixelsWide) * scale,
                          height: CGFloat(sourceRep.pixelsHigh) * scale)
        source.draw(in: NSRect(x: (CGFloat(width) - size.width) / 2,
                               y: (CGFloat(height) - size.height) / 2,
                               width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let bytes = bitmap.representation(using: .png, properties: [:]),
          let check = NSBitmapImageRep(data: bytes) else { fatalError("Cannot encode artwork") }
    precondition(check.pixelsWide == width && check.pixelsHigh == height)
    precondition(layer == .foreground ? check.colorAt(x: 0, y: 0)!.alphaComponent == 0 :
                                      check.colorAt(x: 0, y: 0)!.alphaComponent == 1)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: url)
}

func imageSet(_ url: URL, width: Int, height: Int, scales: [Int], layer: Layer) throws {
    var images: [[String: Any]] = []
    for scale in scales {
        let name = "image@\(scale)x.png"
        try png(url.appendingPathComponent(name), width: width * scale, height: height * scale, layer: layer)
        images.append(["idiom": "tv", "scale": "\(scale)x", "filename": name])
    }
    try json(["info": info, "images": images], at: url.appendingPathComponent("Contents.json"))
}

try json(["info": info], at: catalog.appendingPathComponent("Contents.json"))
let brand = catalog.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
var assets: [[String: Any]] = []
for (name, width, height, scales) in [("App Icon", 400, 240, [1, 2]), ("App Store Icon", 1280, 768, [1])] {
    let stack = brand.appendingPathComponent(name + ".imagestack")
    for (layerName, layer) in [("Foreground", Layer.foreground), ("Background", Layer.background)] {
        let directory = stack.appendingPathComponent(layerName + ".imagestacklayer")
        try json(["info": info], at: directory.appendingPathComponent("Contents.json"))
        try imageSet(directory.appendingPathComponent("Content.imageset"), width: width,
                     height: height, scales: scales, layer: layer)
    }
    try json(["info": info, "layers": [["filename": "Foreground.imagestacklayer"],
                                       ["filename": "Background.imagestacklayer"]]],
             at: stack.appendingPathComponent("Contents.json"))
    assets.append(["idiom": "tv", "role": "primary-app-icon", "size": "\(width)x\(height)",
                   "filename": name + ".imagestack"])
}
for (name, width, role) in [("Top Shelf Image", 1920, "top-shelf-image"),
                           ("Top Shelf Image Wide", 2320, "top-shelf-image-wide")] {
    try imageSet(brand.appendingPathComponent(name + ".imageset"), width: width, height: 720,
                 scales: [1, 2], layer: .composite)
    assets.append(["idiom": "tv", "role": role, "size": "\(width)x720", "filename": name + ".imageset"])
}
try json(["info": info, "assets": assets], at: brand.appendingPathComponent("Contents.json"))
try imageSet(catalog.appendingPathComponent("BrandMark.imageset"), width: 160, height: 96,
             scales: [1, 2], layer: .foreground)
try png(root.appendingPathComponent("Artwork/icon-preview.png"), width: 800, height: 480, layer: .composite)
print("Exported layered tvOS icon, top-shelf images and brand mark; PNG size/alpha checks passed.")
