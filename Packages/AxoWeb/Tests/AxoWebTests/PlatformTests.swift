#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Testing
@testable import AxoWeb

struct PlatformTests {
    #if os(macOS)
    @Test func linkModifiersComeFromAppKitFlags() {
        #expect(LinkModifiers(NSEvent.ModifierFlags()) == [])
        #expect(LinkModifiers([.command, .shift]) == [.command, .shift])
        #expect(LinkModifiers([.option, .control, .capsLock]) == [.option, .control], "Only the four modifiers count")
    }
    #else
    @Test func linkModifiersComeFromUIKitFlags() {
        #expect(LinkModifiers(UIKeyModifierFlags()) == [])
        #expect(LinkModifiers([.command, .alternate]) == [.command, .option])
        #expect(LinkModifiers([.shift, .control, .alphaShift]) == [.shift, .control], "Only the four modifiers count")
    }
    #endif
}
