import Foundation
import Testing
@testable import WebbyCore

private func tagNames(_ text: String) -> [String] {
    Tags.parse(text).map(\.name)
}

@Test func parsesSimpleAndMultipleTagsInEncounterOrder() {
    let tags = Tags.parse("#beta and #alpha then #beta")

    #expect(tags == [
        LibraryTag(name: "beta", searchKey: "beta"),
        LibraryTag(name: "alpha", searchKey: "alpha"),
    ])
}

@Test func foldsCaseAndDiacriticsForSearchKeys() {
    let tags = Tags.parse("#CAFÉ #Straße #İstanbul #ÅNGSTRÖM")

    #expect(tags.map(\.searchKey) == ["cafe", "strasse", "istanbul", "angstrom"])
    #expect(tags.map(\.name) == ["CAFÉ", "Straße", "İstanbul", "ÅNGSTRÖM"])
}

@Test func normalizesDisplayNamesToNFCAndKeepsFirstOccurrence() {
    let tags = Tags.parse("#cafe\u{301} #CAFÉ #cafe\u{301}")

    #expect(tags == [LibraryTag(name: "café", searchKey: "cafe")])
}

@Test func deduplicatesBySearchKeyButKeepsFirstDisplaySpelling() {
    #expect(tagNames("#Tag #tag #TAG") == ["Tag"])
    #expect(tagNames("#Éclair #eclair") == ["Éclair"])
}

@Test func allowsUnderscoreDigitsAndHyphensAfterTheFirstScalar() {
    #expect(tagNames("#a-b_c9 #9lives #_private") == ["a-b_c9", "9lives", "_private"])
}

@Test func allowsCombiningMarksInContinuation() {
    #expect(tagNames("#e\u{301}x") == ["e\u{301}x"])
    #expect(Tags.parse("#e\u{301}x")[0].name == "éx")
}

@Test func stopsAtPunctuationAndWhitespace() {
    #expect(tagNames("#one,two #three. #four! #five?") == ["one", "three", "four", "five"])
    #expect(tagNames("#a/b #c\\d #e#f") == ["a", "c", "e"])
}

@Test func requiresAStartOrNonBlockingBoundary() {
    #expect(tagNames("start #ok") == ["ok"])
    #expect(tagNames("foo#bar") == [])
    #expect(tagNames("foo_#bar") == [])
    #expect(tagNames("1#bar") == [])
    #expect(tagNames("foo-#bar") == ["bar"])
    #expect(tagNames("😀#bar") == ["bar"])
}

@Test func rejectsPathsEscapesAndAdjacentHashes() {
    #expect(tagNames("/#tag") == [])
    #expect(tagNames("\\#tag") == [])
    #expect(tagNames("##tag") == [])
    #expect(tagNames("#tag/#other") == ["tag"])
    #expect(tagNames("#tag\\#other") == ["tag"])
}

@Test func rejectsLoneAndInvalidFirstScalars() {
    #expect(tagNames("#") == [])
    #expect(tagNames("# ") == [])
    #expect(tagNames("#-tag") == [])
    #expect(tagNames("#\u{301}tag") == [])
    #expect(tagNames("#😀") == [])
    #expect(tagNames("#.tag") == [])
    #expect(tagNames("# tag") == [])
}

@Test func skipsFragmentsInHTTPAndHTTPSTags() {
    #expect(tagNames("https://example.com/page#section #real") == ["real"])
    #expect(tagNames("http://example.com/#frag") == [])
    #expect(tagNames("HTTPS://EXAMPLE.COM/PAGE#Frag #real") == ["real"])
}

@Test func skipsFragmentsInCustomSchemeURLs() {
    #expect(tagNames("webby://note/ABC#fragment #real") == ["real"])
    #expect(tagNames("mailto:person@example.com#ignored") == [])
    #expect(tagNames("x-custom+v1.2://host/a#tag #kept") == ["kept"])
}

@Test func skipsFragmentsInWWWURLsCaseInsensitively() {
    #expect(tagNames("www.example.com/path#frag #real") == ["real"])
    #expect(tagNames("WWW.EXAMPLE.COM/PATH#frag") == [])
    #expect(tagNames("See www.example.com/a#b, then #kept") == ["kept"])
}

@Test func urlSpansEndAtWhitespaceOrAngleAndQuoteDelimiters() {
    #expect(tagNames("<https://example.com#frag> #kept") == ["kept"])
    #expect(tagNames("\"https://example.com#frag\" #kept") == ["kept"])
    #expect(tagNames("(https://example.com#frag) #kept") == ["kept"])
    #expect(tagNames("https://example.com#frag\n#kept") == ["kept"])
}

@Test func requiresAURLBoundaryBeforeSchemesAndWWW() {
    #expect(tagNames("foo_https://example.com#frag #kept") == ["kept"])
    #expect(tagNames("foo_www.example.com#frag #kept") == ["kept"])
    #expect(tagNames("1www.example.com#frag #kept") == ["kept"])
}

@Test func urlDetectionDoesNotConsumeFollowingSeparatedTags() {
    #expect(tagNames("https://example.com/a#x #one https://example.com/b#y #two") == ["one", "two"])
}

@Test func returnsNoTagsForPlainTextAndPunctuation() {
    #expect(Tags.parse("").isEmpty)
    #expect(Tags.parse("no tags here").isEmpty)
    #expect(Tags.parse("email@example.com").isEmpty)
    #expect(Tags.parse("C# and F#").isEmpty)
}

@Test func tagNamesAreNotLoggedOrMutated() {
    let text = "#alpha #beta"
    let tags = Tags.parse(text)

    #expect(tags.map(\.name) == ["alpha", "beta"])
    #expect(text == "#alpha #beta")
}
