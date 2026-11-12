import CoreGraphics
import Foundation
import ImageIO

public enum ImageConvert {
    /// Converts 1 image to JPEG next to the original, keeping it. Returns the new file's path.
    public static func toJPEG(_ path: String, quality: Double = 0.9) throws -> String {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw OperationError.failed("Convert to JPEG", "\((path as NSString).lastPathComponent): not a readable image")
        }
        let folder = (path as NSString).deletingLastPathComponent
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = FileOps.uniqueName("\(stem).jpg", in: folder)
        let dest = (folder as NSString).appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dest) as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw OperationError.failed("Convert to JPEG", "can't create \(name)")
        }
        // AddImageFromSource (rather than decoding to a CGImage and re-adding it) carries the source's
        // metadata — including EXIF/TIFF orientation — into the destination, so photos aren't silently
        // flattened to "right side up" pixel data and end up sideways/upside-down after conversion.
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw OperationError.failed("Convert to JPEG", "can't write \(name)")
        }
        return dest
    }
}
