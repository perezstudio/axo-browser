import Foundation
import Testing
@testable import AxoUI

struct AddressInputTests {
    @Test(arguments: [
        ("https://example.com", "https://example.com"),
        ("http://example.com/a?b=c", "http://example.com/a?b=c"),
        ("  https://example.com  ", "https://example.com"),
        ("file:///tmp/page.html", "file:///tmp/page.html"),
        ("about:blank", "about:blank"),
        ("example.com", "https://example.com"),
        ("swift.org/documentation", "https://swift.org/documentation"),
        ("sub.example.co.uk:8443/path", "https://sub.example.co.uk:8443/path"),
        ("localhost:3000", "http://localhost:3000"),
        ("127.0.0.1:8080/api", "http://127.0.0.1:8080/api"),
        ("axo.test", "http://axo.test"),
        ("app.localhost/login", "http://app.localhost/login"),
    ])
    func addressesLoadAsURLs(input: String, expected: String) {
        #expect(AddressInput.url(from: input)?.absoluteString == expected)
    }

    @Test(arguments: ["axolotl", "what is 1.5 times 2", "swift concurrency", "example.", ".com"])
    func everythingElseIsASearch(input: String) throws {
        let url = try #require(AddressInput.url(from: input))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(url.host() == AddressInput.searchURL.host())
        #expect(components.queryItems == [URLQueryItem(name: "q", value: input)])
    }

    @Test func dataURLsWithMarkupLoad() throws {
        let url = try #require(AddressInput.url(from: "data:text/html,<title>Hi</title>"))
        #expect(url.scheme == "data")
    }

    @Test(arguments: ["", "   ", "\n"])
    func emptyInputLoadsNothing(input: String) {
        #expect(AddressInput.url(from: input) == nil)
    }
}
