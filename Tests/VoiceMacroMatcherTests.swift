import Foundation

enum VoiceMacroMatcherTests {
    static func run() {
        testMatchingIsCaseAndPunctuationInsensitive()
        testEmptyAndPartialCommandsDoNotMatch()
        testUpdatingMacrosReplacesTheLookupTable()
    }

    private static func testMatchingIsCaseAndPunctuationInsensitive() {
        let macro = VoiceMacro(command: "Synthetic greeting", payload: "Hello, fixture!")
        let matcher = VoiceMacroMatcher()
        matcher.update([macro])

        TestSupport.expectEqual(
            matcher.match(transcript: "  SYNTHETIC, GREETING!!!  "),
            macro
        )
    }

    private static func testEmptyAndPartialCommandsDoNotMatch() {
        let matcher = VoiceMacroMatcher()
        matcher.update([VoiceMacro(command: "Synthetic greeting", payload: "Fixture")])

        TestSupport.expectEqual(matcher.match(transcript: ""), nil)
        TestSupport.expectEqual(matcher.match(transcript: "Synthetic"), nil)
    }

    private static func testUpdatingMacrosReplacesTheLookupTable() {
        let first = VoiceMacro(command: "First synthetic macro", payload: "One")
        let second = VoiceMacro(command: "Second synthetic macro", payload: "Two")
        let matcher = VoiceMacroMatcher()
        matcher.update([first])
        matcher.update([second])

        TestSupport.expectEqual(matcher.match(transcript: first.command), nil)
        TestSupport.expectEqual(matcher.match(transcript: second.command), second)
    }
}
