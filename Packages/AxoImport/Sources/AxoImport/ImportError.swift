import Foundation

/// Errors thrown while reading another browser's data.
public enum ImportError: Error, Equatable, LocalizedError {
    /// The browser's data isn't where it should be, for example because it isn't installed.
    case notFound(URL)
    /// The file exists but couldn't be read, usually because macOS didn't allow access.
    case unreadable(URL)
    /// The file isn't in the format Axo expects, for example after a browser update.
    case unrecognizedFormat(URL)

    public var errorDescription: String? {
        switch self {
        case .notFound(let url): "Axo couldn't find \(url.lastPathComponent)."
        case .unreadable(let url): "macOS didn't allow Axo to read \(url.lastPathComponent)."
        case .unrecognizedFormat(let url): "Axo doesn't recognize the format of \(url.lastPathComponent)."
        }
    }

    /// Reads a file, turning failures into an ``ImportError``.
    static func read(_ url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ImportError.notFound(url) }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ImportError.unreadable(url)
        }
    }

    /// Decodes JSON as a dictionary, turning failures into ``unrecognizedFormat(_:)``.
    static func jsonObject(_ data: Data, from url: URL) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.unrecognizedFormat(url)
        }
        return object
    }
}
