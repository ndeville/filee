import CoreGraphics
import Foundation
import ImageIO

public enum ImageConvert {
    /// Converts 1 image to JPEG next to the original, keeping it. Returns the new file's path.
    public static func toJPEG(_ path: String, quality: Double = 0.9) throws -> String {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OperationError.failed("Convert to JPEG", "\((path as NSString).lastPathComponent): not a readable image")
        }
        let folder = (path as NSString).deletingLastPathComponent
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = FileOps.uniqueName("\(stem).jpg", in: folder)
        let dest = (folder as NSString).appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dest) as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw OperationError.failed("Convert to JPEG", "can't create \(name)")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw OperationError.failed("Convert to JPEG", "can't write \(name)")
        }
        return dest
    }
}
