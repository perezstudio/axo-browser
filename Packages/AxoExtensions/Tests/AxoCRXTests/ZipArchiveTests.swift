import Foundation
import Testing
import AxoCRXTestSupport
@testable import AxoCRX

struct ZipArchiveTests {
    let destination = temporaryFolder()

    @Test func extractsStoredAndDeflatedFilesAndFolders() throws {
        let written = try ZipArchive.extract(sampleExtensionZip(), to: destination)

        #expect(Set(written) == ["manifest.json", "background.js", "icons/readme.txt"])
        #expect(try String(contentsOf: destination.appending(path: "icons/readme.txt"), encoding: .utf8) == "icons go here")
        #expect(try String(contentsOf: destination.appending(path: "background.js"), encoding: .utf8).contains("hello"))
    }

    @Test(arguments: ["../escape.txt", "/etc/escape.txt", "a/../../escape.txt", "a\\..\\escape.txt", "./"])
    func pathsOutsideTheFolderAreRefused(name: String) {
        var zip = ZipBuilder()
        zip.add(name, "nope")
        #expect(throws: ZipError.unsafeEntry(name)) { try ZipArchive.extract(zip.build(), to: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().appending(path: "escape.txt").path))
    }

    @Test func symlinksAreRefused() {
        var zip = ZipBuilder()
        zip.entries.append(.init(name: "link", data: Data("/etc/passwd".utf8), isSymlink: true))
        #expect(throws: ZipError.unsafeEntry("link")) { try ZipArchive.extract(zip.build(), to: destination) }
    }

    @Test func corruptDataIsRefused() {
        var zip = ZipBuilder()
        zip.entries.append(.init(name: "bad.txt", data: Data("payload".utf8), corruptCRC: true))
        #expect(throws: ZipError.corruptEntry("bad.txt")) { try ZipArchive.extract(zip.build(), to: destination) }
    }

    @Test func archivesOverTheSizeLimitAreRefused() {
        var zip = ZipBuilder()
        zip.add("big.txt", String(repeating: "a", count: 10_000), deflate: true)
        #expect(throws: ZipError.tooLarge) { try ZipArchive.extract(zip.build(), to: destination, sizeLimit: 1_000) }
    }

    @Test func nonZipDataIsRefused() {
        #expect(throws: ZipError.notAZipArchive) { try ZipArchive.extract(Data("not a zip".utf8), to: destination) }
    }

    @Test func crc32MatchesTheStandardCheckValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}
