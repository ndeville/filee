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
}
