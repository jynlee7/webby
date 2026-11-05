import Foundation
import Testing
@testable import WebbyCore

private let noteLinkID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

@Test func noteLinkBuildsTheExactWebbyURL() {
    #expect(NoteLink.url(for: noteLinkID) == "webby://note/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
}

@Test func noteLinkRoundTripsCanonicalAndLowercaseUUIDs() {
    #expect(NoteLink.parse(NoteLink.url(for: noteLinkID)) == noteLinkID)
    #expect(
        NoteLink.parse("webby://note/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee") == noteLinkID
    )
}

@Test func noteLinkAcceptsCaseInsensitiveSchemeAndHost() {
    #expect(
        NoteLink.parse("WEBby://NOTE/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") == noteLinkID
    )
}

@Test func noteLinkRejectsExtraPathComponents() {
    #expect(NoteLink.parse("webby://note/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/extra") == nil)
    #expect(NoteLink.parse("webby://note/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE//") == nil)
    #expect(NoteLink.parse("webby://note/") == nil)
    #expect(NoteLink.parse("webby://note") == nil)
}

@Test func noteLinkRejectsQueryAndFragment() {
    #expect(NoteLink.parse("webby://note/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE?x=1") == nil)
    #expect(NoteLink.parse("webby://note/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE?") == nil)
    #expect(NoteLink.parse("webby://note/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE#frag") == nil)
    #expect(NoteLink.parse("webby://note/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE#") == nil)
}

@Test func noteLinkRejectsCredentialsAndPorts() {
    #expect(NoteLink.parse("webby://user:pass@note/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") == nil)
    #expect(NoteLink.parse("webby://user@note/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") == nil)
    #expect(NoteLink.parse("webby://note:8080/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") == nil)
}

@Test func noteLinkRejectsWrongSchemeAndHost() {
    #expect(NoteLink.parse("http://note/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") == nil)
    #expect(NoteLink.parse("webby://other/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") == nil)
    #expect(NoteLink.parse("webby:note/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") == nil)
    #expect(NoteLink.parse("not a url") == nil)
    #expect(NoteLink.parse("") == nil)
}

@Test func noteLinkRejectsMalformedUUIDs() {
    #expect(NoteLink.parse("webby://note/not-a-uuid") == nil)
    #expect(NoteLink.parse("webby://note/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE") == nil)
    #expect(NoteLink.parse("webby://note/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEEE") == nil)
    #expect(NoteLink.parse("webby://note/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE-") == nil)
    #expect(NoteLink.parse("webby://note/{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}") == nil)
}
