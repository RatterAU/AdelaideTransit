import Testing
@testable import AdelaideTransit

/// Cases here are trimmed from real Adelaide Metro service_alerts payloads.
struct HTMLTextTests {

    @Test func plainTextPassesThroughUntouched() {
        #expect(HTMLText.plain("Stop 12 relocated.") == "Stop 12 relocated.")
    }

    @Test func stripsWrappingDivsAndParagraphs() {
        let html = "<div id=\"component_1477988\"><p>Stop U1 Halifax St will be relocated.</p></div>"
        #expect(HTMLText.plain(html) == "Stop U1 Halifax St will be relocated.")
    }

    @Test func paragraphsBecomeSeparateLines() {
        let html = "<p>Stop 2 will be closed.</p><p>Use Stop 3A instead.</p>"
        #expect(HTMLText.plain(html) == "Stop 2 will be closed.\nUse Stop 3A instead.")
    }

    /// The feed repeats the same wrapper div up to five times; naive stripping left a ladder of blank lines.
    @Test func repeatedNestedDivsDoNotProduceBlankLines() {
        let html = "<div id=\"c\"><div id=\"c\"><div id=\"c\"><p>Detour in place.</p></div></div></div>"
        #expect(HTMLText.plain(html) == "Detour in place.")
    }

    @Test func listItemsBecomeBullets() {
        let html = "<ul><li>Stop 19 South Rd</li><li>Stop 20 South Rd</li></ul>"
        #expect(HTMLText.plain(html) == "• Stop 19 South Rd\n• Stop 20 South Rd")
    }

    @Test func decodesNamedEntities() {
        #expect(HTMLText.plain("<p>Stop 22 York Avenue &ndash; south of Byron Ave&nbsp;</p>")
            == "Stop 22 York Avenue – south of Byron Ave")
    }

    @Test func decodesNumericEntitiesInBothBases() {
        #expect(HTMLText.plain("caf&#233; &#x26; bar") == "café & bar")
    }

    @Test func decodesAmpersandWithoutMangling() {
        #expect(HTMLText.plain("<p>Ashwin &amp; Thebarton</p>") == "Ashwin & Thebarton")
    }

    /// An escaped entity stays escaped once: `&amp;lt;` is the text "&lt;", on every launch.
    @Test func decodesAmpersandOnlyOnce() {
        #expect(HTMLText.plain("a &amp;lt; b") == "a &lt; b")
    }

    @Test func lineBreakTagsSplitLines() {
        #expect(HTMLText.plain("Line one<br/>Line two") == "Line one\nLine two")
    }

    @Test func dropsAttributesAndInlineSpans() {
        let html = "<p data-start=\"107\">Use Stop 14D<span class=\"markpr5\" data-ogac=\"\">Edward</span> St</p>"
        #expect(HTMLText.plain(html) == "Use Stop 14DEdward St")
    }

    @Test func linkTextSurvivesTheAnchorTag() {
        let html = "<p>Info here: <a href=\"https://www.t2d.sa.gov.au/\">https://www.t2d.sa.gov.au/</a></p>"
        #expect(HTMLText.plain(html) == "Info here: https://www.t2d.sa.gov.au/")
    }

    @Test func tableRowsFlattenToOneLineEach() {
        let html = "<table><tbody><tr><td>Stop 77D</td><td>Stop 77E</td></tr>"
            + "<tr><td>Stop 77C</td><td>Stop 77J</td></tr></tbody></table>"
        #expect(HTMLText.plain(html) == "Stop 77D — Stop 77E\nStop 77C — Stop 77J")
    }

    @Test func trailingNonBreakingSpaceParagraphsAreDropped() {
        let html = "<p>Closed until further notice.</p><p>&nbsp;</p>"
        #expect(HTMLText.plain(html) == "Closed until further notice.")
    }

    @Test func emptyInputStaysEmpty() {
        #expect(HTMLText.plain("") == "")
    }
}
