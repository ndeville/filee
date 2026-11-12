import CoreGraphics
import Foundation
import ImageIO

public enum PDFBuilder {
    /// Combines images into 1 PDF, 1 page per image in the given order, next to the first image. Returns the PDF's path.
    public static func fromImages(_ paths: [String]) throws -> String {
        guard let first = paths.first else { throw OperationError.failed("Create PDF", "nothing selected") }
        let folder = (first as NSString).deletingLastPathComponent
        let base = paths.count == 1 ? ((first as NSString).lastPathComponent as NSString).deletingPathExtension + ".pdf" : "Document.pdf"
        // Write to a private temp file first, not straight to the real destination: CGContext opens
        // the file for writing immediately, before any page is drawn, so if a later image in the
        // selection turns out to be unreadable and this throws partway through the loop below, a
        // broken, misleadingly-named partial file would otherwise be left sitting in the user's folder
        // with no undo entry (no path is ever returned on failure). Only move it into place, under a
        // name computed fresh against the folder's current contents, once every page has succeeded.
        let tempPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("filee-pdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(atPath: tempPath) }
        guard let context = CGContext(URL(fileURLWithPath: tempPath) as CFURL, mediaBox: nil, nil) else {
            throw OperationError.failed("Create PDF", "can't create a PDF")
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
        let dest = (folder as NSString).appendingPathComponent(FileOps.uniqueName(base, in: folder))
        try FileManager.default.moveItem(atPath: tempPath, toPath: dest)
        return dest
    }
}
