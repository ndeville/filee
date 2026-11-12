import CoreGraphics
import Foundation
import ImageIO

public enum PDFBuilder {
    /// Combines images into 1 PDF, 1 page per image in the given order, next to the first image. Returns the PDF's path.
    public static func fromImages(_ paths: [String]) throws -> String {
        guard let first = paths.first else { throw OperationError.failed("Create PDF", "nothing selected") }
        let folder = (first as NSString).deletingLastPathComponent
        let base = paths.count == 1 ? ((first as NSString).lastPathComponent as NSString).deletingPathExtension + ".pdf" : "Document.pdf"
        let dest = (folder as NSString).appendingPathComponent(FileOps.uniqueName(base, in: folder))
        guard let context = CGContext(URL(fileURLWithPath: dest) as CFURL, mediaBox: nil, nil) else {
            throw OperationError.failed("Create PDF", "can't create \(dest)")
        }
        for p in paths {
            // CGImageSourceCreateImageAtIndex decodes raw pixels and ignores EXIF/TIFF orientation; a
            // phone photo tagged sideways/upside-down would land on the PDF page exactly as stored,
            // i.e. sideways/upside-down. CGImageSourceCreateThumbnailAtIndex with WithTransform bakes
            // the orientation into the returned pixels instead, so the page comes out right-side up.
            // Passing max(width, height) as the max pixel size means "don't downscale" (the thumbnail
            // API won't upscale past the source's own size), so this is full resolution, not a preview.
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: max(w, h)
                  ] as CFDictionary) else {
                throw OperationError.failed("Create PDF", "\((p as NSString).lastPathComponent): not a readable image")
            }
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
        return dest
    }
}
