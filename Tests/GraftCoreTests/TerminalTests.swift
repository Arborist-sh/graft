import Foundation
import Testing
@testable import GraftCore

@Suite("Terminal key decoding")
struct KeyDecodeTests {
    @Test("arrow keys decode from their 3-byte CSI escapes")
    func arrows() {
        #expect(decodeKey([0x1B, 0x5B, 0x41]) == .up)
        #expect(decodeKey([0x1B, 0x5B, 0x42]) == .down)
        #expect(decodeKey([0x1B, 0x5B, 0x43]) == .other)   // right — ignored
        #expect(decodeKey([0x1B, 0x5B, 0x44]) == .other)   // left — ignored
    }

    @Test("enter accepts CR and LF; backspace accepts DEL and BS")
    func enterAndBackspace() {
        #expect(decodeKey([0x0D]) == .enter)
        #expect(decodeKey([0x0A]) == .enter)
        #expect(decodeKey([0x7F]) == .backspace)
        #expect(decodeKey([0x08]) == .backspace)
    }

    @Test("control + escape + printable chars")
    func miscKeys() {
        #expect(decodeKey([0x03]) == .ctrlC)
        #expect(decodeKey([0x1B]) == .escape)
        #expect(decodeKey([0x61]) == .char("a"))
        #expect(decodeKey([0x5A]) == .char("Z"))
        #expect(decodeKey([0x00]) == .other)               // NUL → other
        #expect(decodeKey([]) == .other)
    }
}

@Suite("Select state")
struct SelectStateTests {
    @Test("starts with every option visible and the cursor at the top")
    func initial() {
        let s = SelectState(options: ["a", "b", "c"])
        #expect(s.filtered == [0, 1, 2])
        #expect(s.cursor == 0)
        #expect(s.selectedOptionIndex == 0)
    }

    @Test("up/down clamp at the ends")
    func navigationClamps() {
        var s = SelectState(options: ["a", "b", "c"])
        s.up()                       // already at top
        #expect(s.cursor == 0)
        s.down(); s.down(); s.down() // can't pass the end
        #expect(s.cursor == 2)
        #expect(s.selectedOptionIndex == 2)
    }

    @Test("filtering is case-insensitive substring; cursor maps back to the real option")
    func filtering() {
        var s = SelectState(options: ["alpha", "beta", "gamma", "delta"])
        s.appendToQuery("E")        // uppercase typed
        s.appendToQuery("l")        // "el" matches only "delta"
        #expect(s.filtered == [3])
        #expect(s.selectedOptionIndex == 3)
    }

    @Test("cursor re-clamps when a filter shrinks the list, and restores on backspace")
    func filterClamp() {
        var s = SelectState(options: ["alpha", "beta", "gamma", "delta"])
        s.down(); s.down(); s.down()    // cursor at 3 (delta)
        for c in "alph" { s.appendToQuery(c) }   // → only "alpha" (index 0)
        #expect(s.filtered == [0])
        #expect(s.cursor == 0)
        #expect(s.selectedOptionIndex == 0)
        s.backspaceQuery(); s.backspaceQuery(); s.backspaceQuery(); s.backspaceQuery()
        #expect(s.filtered == [0, 1, 2, 3])   // query empty again
    }

    @Test("the scroll window stays at maxVisible and keeps the cursor in view")
    func window() {
        var s = SelectState(options: (0..<20).map(String.init), maxVisible: 10)
        #expect(s.window == 0..<10)                 // cursor at top
        for _ in 0..<19 { s.down() }                // cursor at 19 (last)
        #expect(s.window == 10..<20)                 // window scrolled to the bottom
        #expect(s.window.contains(s.cursor))
    }

    @Test("a list shorter than maxVisible shows everything")
    func shortList() {
        let s = SelectState(options: ["a", "b"], maxVisible: 10)
        #expect(s.window == 0..<2)
    }
}
