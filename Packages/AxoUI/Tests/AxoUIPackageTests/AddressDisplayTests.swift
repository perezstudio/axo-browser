import Foundation
import Testing
@testable import AxoUI

/// What the sidebar's address bar shows for each kind of page.
struct AddressDisplayTests {
    private func text(_ address: String, fullAddress: Bool = false) -> String? {
        AddressDisplay.text(for: URL(string: address)!, fullAddress: fullAddress)
    }

    @Test func webPagesShowTheirSimplifiedHost() {
        #expect(text("https://www.example.com/path?query=1#top") == "example.com")
        #expect(text("http://Example.COM/") == "example.com")
        #expect(text("https://docs.example.com/a/b") == "docs.example.com")
        #expect(text("https://www.com/") == "www.com", "Not when only a top-level domain would be left")
        #expect(text("https://wwwexample.com/") == "wwwexample.com")
    }

    @Test func portsShowWhenTheyArentTheDefault() {
        #expect(text("http://localhost:3000/app") == "localhost:3000")
        #expect(text("https://example.com:443/") == "example.com")
        #expect(text("http://example.com:80/") == "example.com")
        #expect(text("https://example.com:8443/") == "example.com:8443")
    }

    @Test func ipAddressesShowAsTheyAre() {
        #expect(text("http://192.168.1.10:8080/") == "192.168.1.10:8080")
        #expect(text("http://[::1]:8000/") == "[::1]:8000")
        #expect(text("http://[2001:db8::1]/") == "[2001:db8::1]")
    }

    @Test func internationalNamesShowInTheirOwnScript() {
        #expect(text("https://xn--bcher-kva.de/") == "bücher.de")
        #expect(text("https://www.xn--mnchen-3ya.de/") == "münchen.de")
        #expect(text("https://xn--fsq.xn--0zwm56d/") == "例.测试")
        #expect(text("https://xn--invalid-!.example/") == "xn--invalid-!.example", "A label that doesn't decode stays")
        #expect(text("https://xn--p1ai.xn--p1ai/") == "рф.рф", "Cyrillic under a Cyrillic top-level domain")
        #expect(text("https://xn--n3h.example/") == "xn--n3h.example", "Symbols (☃) aren't a script")
    }

    @Test func lookalikeNamesStayInTheirASCIIForm() {
        // аррӏе.com, all Cyrillic, looks just like apple.com.
        #expect(text("https://xn--80ak6aa92e.com/") == "xn--80ak6aa92e.com")
        // pаypal.com mixes Latin and a Cyrillic а.
        #expect(text("https://xn--pypal-4ve.com/") == "xn--pypal-4ve.com")
        // The whole host stays ASCII when any label isn't safe.
        #expect(text("https://xn--bcher-kva.xn--80ak6aa92e.com/") == "xn--bcher-kva.xn--80ak6aa92e.com")
    }

    @Test func malformedEncodedNamesStayAsTheyAre() {
        #expect(text("https://xn--google-.com/") == "xn--google-.com", "Decodes to plain ASCII: not a real encoding")
        #expect(text("https://xn--.com/") == "xn--.com", "Decodes to nothing")
    }

    @Test func singleScriptChecks() {
        #expect(Punycode.singleScript(of: "bücher") == .latin)
        #expect(Punycode.singleScript(of: "例え") == .japanese, "Han with kana is Japanese")
        #expect(Punycode.singleScript(of: "pаypal") == nil, "Mixed scripts")
        #expect(Punycode.singleScript(of: "a\u{200B}b") == nil, "Invisible characters")
        #expect(Punycode.singleScript(of: "a\u{2024}b") == nil, "Something that looks like a dot")
    }

    @Test func punycodeDecodesRFC3492Samples() {
        #expect(Punycode.decode("bcher-kva") == "bücher")
        #expect(Punycode.decode("ihqwcrb4cv8a8dqg056pqjye") == "他们为什么不说中文")
        #expect(Punycode.decode(String(repeating: "9", count: 40)) == nil, "Too large to be a character, not a crash")
        #expect(Punycode.decode("ab!") == nil, "Not a Punycode digit")
    }

    @Test func pagesWithoutAHostShowSomethingReadable() {
        #expect(text("about:blank") == "Start Page")
        #expect(text("file:///Users/someone/Documents/notes.html") == "notes.html")
        #expect(text("data:text/html,<title>x</title>") == "Data page")
        #expect(text("about:srcdoc") == "about:srcdoc")
        #expect(AddressDisplay.text(for: nil) == nil)
    }

    @Test func theSearchPageShowsWhatWasSearched() {
        let search = AddressInput.searchURL(for: "axolotl facts")
        #expect(AddressDisplay.text(for: search) == "axolotl facts")
        #expect(text("https://duckduckgo.com/?q=") == "duckduckgo.com", "No terms: the site")
        #expect(text("https://duckduckgo.com/settings?q=x") == "duckduckgo.com", "Not the results page")
        #expect(AddressDisplay.shown(for: search)?.kind == .search, "Marked as a search")
    }

    @Test func searchTermsCantPassForASite() {
        #expect(AddressDisplay.text(for: AddressInput.searchURL(for: "paypal.com")) == "duckduckgo.com", "Terms that look like an address")
        #expect(AddressDisplay.text(for: AddressInput.searchURL(for: "https://bank.example")) == "duckduckgo.com")
        #expect(AddressDisplay.text(for: AddressInput.searchURL(for: "good \u{202E}moc.knab")) == "good moc.knab", "Right-to-left overrides go")
        #expect(AddressDisplay.text(for: URL(string: "http://duckduckgo.com/?q=axolotl")!) == "duckduckgo.com", "Only over https")
    }

    @Test func plainHTTPSitesAreMarkedNotSecure() {
        #expect(AddressDisplay.shown(for: URL(string: "http://example.com/")!)?.kind == .notSecure)
        #expect(AddressDisplay.shown(for: URL(string: "http://example.com/")!, fullAddress: true)?.kind == .notSecure)
        #expect(AddressDisplay.shown(for: URL(string: "https://example.com/")!)?.kind == .page)
        #expect(AddressDisplay.shown(for: URL(string: "http://localhost:3000/")!)?.kind == .page, "This Mac")
    }

    @Test func theFullAddressSettingShowsEverything() {
        #expect(text("https://www.example.com/path?query=1", fullAddress: true) == "https://www.example.com/path?query=1")
    }
}
