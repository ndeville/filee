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
        // Write to a private temp file first, not straight to the real destination: a truncated/corrupt
        // source (a partial HEIC/PNG/JPEG) can still pass the CGImageSourceGetCount > 0 check above AND
        // make CGImageDestinationFinalize below return true, while the bytes it actually wrote are a
        // broken, unreadable "JPEG" (confirmed with a real ImageIO probe — this isn't hypothetical).
        // Neither check alone proves the output is good, so finalize into a temp file, re-open *that*
        // and require real pixel dimensions before trusting it, and only move it into place on success —
        // the same hazard `PDFBuilder.fromImages` already guards against for the same reason.
        let tempPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("filee-jpeg-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(atPath: tempPath) }
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: tempPath) as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw OperationError.failed("Convert to JPEG", "\((path as NSString).lastPathComponent): can't create a JPEG")
        }
        // AddImageFromSource (rather than decoding to a CGImage and re-adding it) carries the source's
        // metadata — including EXIF/TIFF orientation — into the destination, so photos aren't silently
        // flattened to "right side up" pixel data and end up sideways/upside-down after conversion.
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw OperationError.failed("Convert to JPEG", "\((path as NSString).lastPathComponent): can't write a JPEG")
        }
        // Finalize() returning true does not mean the written bytes are actually a readable image (see
        // note above), so re-open the temp file and require both pixel dimensions to be present and > 0.
        guard let outSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: tempPath) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(outSource, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, w > 0,
              let h = props[kCGImagePropertyPixelHeight] as? Int, h > 0 else {
            throw OperationError.failed("Convert to JPEG", "\((path as NSString).lastPathComponent): source image is damaged")
        }
        let folder = (path as NSString).deletingLastPathComponent
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let dest = (folder as NSString).appendingPathComponent(FileOps.uniqueName("\(stem).jpg", in: folder))
        try FileManager.default.moveItem(atPath: tempPath, toPath: dest)
        return dest
    }
}
