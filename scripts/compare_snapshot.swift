import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Pixels {
    let width: Int
    let height: Int
    var rgba: [UInt8]

    init(path: String) throws {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CocoaError(.fileReadCorruptFile) }
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw CocoaError(.fileReadCorruptFile) }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        rgba = bytes
    }
}

let current = try Pixels(path: CommandLine.arguments[1])
var result: [String: Any] = ["width": current.width, "height": current.height, "compared": false]
if CommandLine.arguments.count > 2 && !CommandLine.arguments[2].isEmpty {
    let baseline = try Pixels(path: CommandLine.arguments[2])
    guard current.width == baseline.width, current.height == baseline.height
    else { throw CocoaError(.fileReadCorruptFile) }
    var changed = 0
    for i in stride(from: 0, to: current.rgba.count, by: 4) {
        if current.rgba[i..<i+4] != baseline.rgba[i..<i+4] { changed += 1 }
    }
    result["compared"] = true
    result["differentPixels"] = changed
    result["differentFraction"] = Double(changed) / Double(current.width * current.height)
}
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
