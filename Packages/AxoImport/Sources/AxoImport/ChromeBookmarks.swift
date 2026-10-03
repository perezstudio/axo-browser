import AxoCore
import Foundation

/// Chrome's bookmarks, read from a profile's `Bookmarks` file.
public enum ChromeBookmarks {
    /// Reads a `Bookmarks` file into one folder for the sidebar's pinned section.
    ///
    /// The bookmarks bar's contents come first, then "Other Bookmarks" and "Mobile Bookmarks"
    /// as subfolders when they aren't empty.
    ///
    /// - Parameters:
    ///   - folderName: The name of the folder holding everything.
    ///   - url: Where the data came from, for error messages.
    /// - Returns: The folder, or `nil` if there are no bookmarks.
    /// - Throws: ``ImportError/unrecognizedFormat(_:)`` if it isn't Chrome's bookmarks format.
    public static func folder(named folderName: String, from data: Data, url: URL) throws -> ImportedItem? {
        let root = try ImportError.jsonObject(data, from: url)
        guard let roots = root["roots"] as? [String: Any] else { throw ImportError.unrecognizedFormat(url) }

        var contents = items(in: roots["bookmark_bar"])
        for (key, name) in [("other", "Other Bookmarks"), ("synced", "Mobile Bookmarks")] {
            let children = items(in: roots[key])
            if !children.isEmpty { contents.append(.folder(name: name, children: children)) }
        }
        return contents.isEmpty ? nil : .folder(name: folderName, children: contents)
    }

    /// The bookmarks and folders inside a Chrome bookmark folder node. Empty folders are kept,
    /// since people make them on purpose.
    private static func items(in node: Any?, depth: Int = 0) -> [ImportedItem] {
        guard depth < 64, let children = (node as? [String: Any])?["children"] as? [[String: Any]] else { return [] }
        return children.compactMap { child in
            let name = child["name"] as? String ?? ""
            switch child["type"] as? String {
            case "url":
                guard let address = child["url"] as? String, let url = URL(string: address), url.scheme != nil else { return nil }
                return .tab(title: name, url: url)
            case "folder":
                return .folder(name: name.isEmpty ? "Folder" : name, children: items(in: child, depth: depth + 1))
            default:
                return nil
            }
        }
    }
}
