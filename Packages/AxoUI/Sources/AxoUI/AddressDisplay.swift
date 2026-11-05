import Foundation

/// What the sidebar's address bar shows for a page: the site, not the whole URL, as Arc does.
nonisolated enum AddressDisplay {
    /// What the bar shows: its text, and what kind of text it is.
    struct Shown: Hashable, Sendable {
        /// What kind of page the text names.
        enum Kind: Hashable, Sendable {
            /// A site over https (or this Mac), or another page.
            case page
            /// A site over plain http: the bar marks it "Not Secure".
            case notSecure
            /// Search terms on the search page: the bar marks them as a search, so they can't pass
            /// for a site's name.
            case search
        }

        var text: String
        var kind: Kind
    }

    /// The text for `url` (see ``shown(for:fullAddress:)``), or `nil` with no page.
    static func text(for url: URL?, fullAddress: Bool = false) -> String? {
        shown(for: url, fullAddress: fullAddress)?.text
    }

    /// What to show for `url`: the simplified host ("example.com", no scheme or `www.`, with a
    /// port that isn't the default), in Unicode for international names that pass
    /// ``Punycode/unicodeHost(_:)``'s checks; something readable for pages without a host ("Start
    /// Page", a `file:` page's file name, "Data page"); the search terms on the search page; and
    /// the whole address with `fullAddress`. `nil` with no page.
    static func shown(for url: URL?, fullAddress: Bool = false) -> Shown? {
        guard let url else { return nil }
        let scheme = url.scheme?.lowercased()
        let kind: Shown.Kind = scheme == "http" && !isLocal(url) ? .notSecure : .page
        if fullAddress { return Shown(text: url.absoluteString, kind: kind) }
        switch scheme {
        case "http", "https":
            if scheme == "https", let terms = searchTerms(in: url) { return Shown(text: terms, kind: .search) }
            guard let host = url.host(percentEncoded: false), !host.isEmpty else { return Shown(text: url.absoluteString, kind: kind) }
            var shown = Punycode.unicodeHost(host.lowercased())
            // "www." goes, unless what's left is only a top-level domain.
            if shown.hasPrefix("www."), shown.dropFirst(4).contains(".") { shown.removeFirst(4) }
            // An IPv6 address keeps its brackets, as in a URL.
            if shown.contains(":") { shown = "[\(shown)]" }
            if let port = url.port, port != (scheme == "https" ? 443 : 80) {
                shown += ":\(port)"
            }
            return Shown(text: shown, kind: kind)
        case "about":
            return Shown(text: url.absoluteString == "about:blank" ? "Start Page" : url.absoluteString, kind: .page)
        case "file":
            let name = url.lastPathComponent
            return Shown(text: name.isEmpty || name == "/" ? url.path : name, kind: .page)
        case "data":
            return Shown(text: "Data page", kind: .page)
        default:
            return Shown(text: url.absoluteString, kind: .page)
        }
    }

    /// Whether `url` is on this Mac, which plain http doesn't make unsafe.
    private static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".localhost")
    }

    /// The search terms when `url` is the search page's results for them. Terms that look like an
    /// address (a page could link to a search for "paypal.com") don't count, and formatting
    /// characters (such as right-to-left overrides) are taken out, so the bar can't be made to
    /// show what looks like a site's name.
    static func searchTerms(in url: URL) -> String? {
        let search = AddressInput.searchURL
        guard url.host()?.lowercased() == search.host()?.lowercased(),
              url.path == search.path || (url.path.isEmpty && search.path == "/"),
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value
        else { return nil }
        var cleaned = String.UnicodeScalarView()
        cleaned.append(contentsOf: raw.unicodeScalars.filter { $0.properties.generalCategory != .format })
        let terms = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty,
              let asAddress = AddressInput.url(from: terms),
              asAddress.host()?.lowercased() == search.host()?.lowercased()
        else { return nil }
        return terms
    }
}

/// Decodes international domain names from their ASCII form (`xn--…`, RFC 3492), for showing.
nonisolated enum Punycode {
    /// `host` with its `xn--` labels decoded, but only when every one of them is safe to show:
    /// it decodes to something that needed encoding (not plain ASCII, not empty), in one script
    /// (or Japanese's mix of Han and kana), with no formatting or invisible characters and nothing
    /// that looks like a dot or a slash. A label in a script whose letters look like Latin ones
    /// (Cyrillic, Greek, Armenian) shows only when the top-level domain is in that script too, as
    /// in Chrome and Safari, so "аррӏе.com" (Cyrillic) stays `xn--80ak6aa92e.com`. Otherwise the
    /// whole host shows as it is.
    static func unicodeHost(_ host: String) -> String {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var decoded: [String] = []
        var scripts: [Script?] = []
        for label in labels {
            guard label.lowercased().hasPrefix("xn--") else {
                decoded.append(label)
                scripts.append(label.allSatisfy(\.isASCII) ? .latin : nil)
                continue
            }
            guard let unicode = decode(String(label.dropFirst(4))),
                  !unicode.isEmpty, !unicode.allSatisfy(\.isASCII),
                  let script = singleScript(of: unicode)
            else { return host }
            decoded.append(unicode)
            scripts.append(script)
        }
        let topLevel = scripts.last ?? nil
        for (label, script) in zip(labels, scripts) where label.lowercased().hasPrefix("xn--") {
            guard let script else { return host }
            if script.looksLikeLatin, script != topLevel { return host }
        }
        return decoded.joined(separator: ".")
    }

    /// The scripts a label may be written in, as far as showing it goes.
    enum Script: Hashable {
        case latin, cyrillic, greek, armenian, japanese, han, hangul, arabic, hebrew, thai, devanagari

        /// Scripts with letters that look like Latin ones.
        var looksLikeLatin: Bool { self == .cyrillic || self == .greek || self == .armenian }

        /// The script of a letter, or `nil` for one that isn't allowed in a shown name.
        init?(_ scalar: Unicode.Scalar) {
            switch scalar.value {
            case 0x61...0x7A, 0xDF...0xF6, 0xF8...0xFF, 0x100...0x17F, 0x180...0x24F, 0x1E00...0x1EFF: self = .latin
            case 0x0400...0x04FF: self = .cyrillic
            case 0x0370...0x03FF: self = .greek
            case 0x0531...0x058F: self = .armenian
            case 0x3041...0x309F, 0x30A0...0x30FF: self = .japanese
            case 0x3400...0x4DBF, 0x4E00...0x9FFF: self = .han
            case 0xAC00...0xD7AF, 0x1100...0x11FF: self = .hangul
            case 0x0620...0x064A, 0x066E...0x06D3: self = .arabic
            case 0x05D0...0x05EA: self = .hebrew
            case 0x0E01...0x0E3A, 0x0E40...0x0E4E: self = .thai
            case 0x0900...0x097F: self = .devanagari
            default: return nil
            }
        }
    }

    /// The one script `label`'s letters are in (digits and hyphens go with any), or `nil` when it
    /// mixes scripts or has a character that isn't allowed. Han mixed with kana is Japanese.
    static func singleScript(of label: String) -> Script? {
        var found: Set<Script> = []
        for scalar in label.unicodeScalars {
            if (0x30...0x39).contains(scalar.value) || scalar == "-" { continue }
            guard let script = Script(scalar) else { return nil }
            found.insert(script)
        }
        if found.count == 1 { return found.first }
        if !found.isEmpty, found.isSubset(of: [.han, .japanese]) { return .japanese }
        return nil
    }

    /// Decodes one Punycode label (without its `xn--` prefix), or `nil` if it isn't valid.
    static func decode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        var output: [Unicode.Scalar] = []
        var basic = Substring(input)
        var encoded = Substring("")
        if let delimiter = input.lastIndex(of: "-") {
            basic = input[..<delimiter]
            encoded = input[input.index(after: delimiter)...]
        } else {
            basic = ""
            encoded = Substring(input)
        }
        for scalar in basic.unicodeScalars {
            guard scalar.isASCII else { return nil }
            output.append(scalar)
        }
        func digit(_ character: Character) -> Int? {
            guard let ascii = character.asciiValue else { return nil }
            switch ascii {
            case 48...57: return Int(ascii) - 22 // 0-9 → 26-35
            case 65...90: return Int(ascii) - 65 // A-Z
            case 97...122: return Int(ascii) - 97 // a-z
            default: return nil
            }
        }
        func adapt(_ delta: Int, _ count: Int, _ first: Bool) -> Int {
            var delta = first ? delta / damp : delta / 2
            delta += delta / count
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 {
                delta /= base - tMin
                k += base
            }
            return k + (base - tMin + 1) * delta / (delta + skew)
        }
        var n = 128, i = 0, bias = 72
        var characters = Array(encoded)
        while !characters.isEmpty {
            let oldI = i
            var w = 1
            var k = base
            while true {
                guard !characters.isEmpty, let d = digit(characters.removeFirst()) else { return nil }
                let (product, overflow) = d.multipliedReportingOverflow(by: w)
                let (sum, sumOverflow) = i.addingReportingOverflow(product)
                guard !overflow, !sumOverflow else { return nil }
                i = sum
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if d < t { break }
                let (weight, weightOverflow) = w.multipliedReportingOverflow(by: base - t)
                guard !weightOverflow else { return nil }
                w = weight
                k += base
            }
            bias = adapt(i - oldI, output.count + 1, oldI == 0)
            let (code, codeOverflow) = n.addingReportingOverflow(i / (output.count + 1))
            guard !codeOverflow, output.count < 256 else { return nil }
            n = code
            i %= output.count + 1
            guard n <= 0x10FFFF, let scalar = Unicode.Scalar(UInt32(n)) else { return nil }
            output.insert(scalar, at: i)
            i += 1
        }
        var result = ""
        result.unicodeScalars.append(contentsOf: output)
        return result
    }
}
