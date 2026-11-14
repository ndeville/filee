import Foundation

/// A tab's file-type filter: every file, or 1 family of documents. Folders always show, so you can still move around.
public enum FileTypeFilter: String, CaseIterable, Sendable {
    case all, pdf, powerpoint, word, excel, markdown, video, images

    public var title: String {
        switch self {
        case .all: return "All Files"
        case .pdf: return "PDF"
        case .powerpoint: return "PowerPoint"
        case .word: return "Word"
        case .excel: return "Excel"
        case .markdown: return "Markdown"
        case .video: return "Video"
        case .images: return "Images"
        }
    }

    /// Lowercase extensions of the family. Excel includes CSV, which opens in Excel.
    public var extensions: Set<String> {
        switch self {
        case .all: return []
        case .pdf: return ["pdf"]
        case .powerpoint: return ["ppt", "pptx", "pptm", "pps", "ppsx", "pot", "potx", "odp"]
        case .word: return ["doc", "docx", "docm", "dot", "dotx", "rtf", "odt"]
        case .excel: return ["xls", "xlsx", "xlsm", "xlsb", "xltx", "csv", "tsv", "ods"]
        case .markdown: return ["md", "markdown", "mdown", "mkd"]
        case .video: return ["mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "wmv", "flv", "3gp", "mts", "m2ts"]
        case .images: return ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "avif", "tiff", "tif", "bmp", "svg", "ico",
                              "psd", "raw", "dng", "cr2", "cr3", "nef", "arw"]
        }
    }

    /// An extension that stands for the family: its file icon is the filter's button.
    public var sampleExtension: String? {
        switch self {
        case .all: return nil
        case .pdf: return "pdf"
        case .powerpoint: return "pptx"
        case .word: return "docx"
        case .excel: return "xlsx"
        case .markdown: return "md"
        case .video: return "mp4"
        case .images: return "png"
        }
    }

    public func matches(_ item: FileItem) -> Bool {
        self == .all || item.isFolder || extensions.contains(item.ext)
    }

    /// Bundle identifiers of real apps recognized as legitimate openers for this family. If the
    /// system's actual default app for `sampleExtension` isn't one of these, the type-filter
    /// button falls back to `bundledFallbackIconName` instead of showing an unrelated app's icon
    /// (e.g. a generic Electron app that happens to have registered `.pptx`).
    public var recognizedAppBundleIDs: Set<String> {
        switch self {
        case .all: return []
        case .pdf: return ["com.apple.Preview", "com.adobe.Reader", "com.adobe.Acrobat.Pro",
                            "com.adobe.Acrobat.Pro.continuous", "com.readdle.PDFExpert-Mac", "com.foxitsoftware.FoxitReader"]
        case .powerpoint: return ["com.microsoft.Powerpoint", "com.apple.iWork.Keynote", "org.libreoffice.script"]
        // TextEdit is deliberately not here: it's Markdown's bundled fallback icon, and Word already
        // has a bundled fallback of its own (Pages) if TextEdit is the only thing installed.
        case .word: return ["com.microsoft.Word", "com.apple.iWork.Pages", "org.libreoffice.script"]
        case .excel: return ["com.microsoft.Excel", "com.apple.iWork.Numbers", "org.libreoffice.script"]
        case .markdown: return ["com.apple.TextEdit", "com.panic.Nova", "com.macromates.TextMate",
                                 "com.sublimetext.4", "com.sublimetext.3", "com.barebones.bbedit",
                                 "com.coteditor.CotEditor", "md.obsidian", "abnerworks.Typora", "com.brettterpstra.marked2"]
        case .video: return ["com.colliderli.iina", "org.videolan.vlc", "com.apple.QuickTimePlayerX"]
        case .images: return ["com.apple.Preview", "com.apple.Photos", "com.seriflabs.affinityphoto2",
                               "com.seriflabs.affinityphoto", "com.adobe.Photoshop", "com.pixelmatorteam.pixelmator.x"]
        }
    }

    /// Base filename (no extension) of this family's bundled Apple-icon PNG in
    /// `FileeMac/Resources/TypeIcons/`, shown when the real default app isn't in
    /// `recognizedAppBundleIDs`. `nil` only for `.all`.
    public var bundledFallbackIconName: String? {
        switch self {
        case .all: return nil
        case .pdf: return "Preview"
        case .powerpoint: return "Keynote"
        case .word: return "Pages"
        case .excel: return "Numbers"
        case .markdown: return "TextEdit"
        case .video: return "QuickTimePlayer"
        case .images: return "Photos"
        }
    }
}
