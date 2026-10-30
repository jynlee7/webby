import Foundation
import Testing
@testable import WebbyAgent

@Test func tokenFixturesAreDisabledWhenAbsent() throws {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebbyMissingTokenFixtures-\(UUID().uuidString)")
    #expect(try TokenCalibration.loadFixtures(from: nil).isEmpty)
    #expect(try TokenCalibration.loadFixtures(from: missing).isEmpty)

    let report = try TokenCalibration.check(directory: missing)
    #expect(report.isSkipped)
    #expect(report == TokenCalibration.Report(status: .skipped(
        reason: "No recorded count_tokens fixtures are present."
    )))
}

@Test func tokenEstimatorInvariantMathHolds() {
    #expect(TokenEstimator.tokens(forCharacters: 0) == 0)
    #expect(TokenEstimator.maxCharacters(forTokens: 0) == 0)

    for characters in 1...200 {
        let expected = Int(ceil(Double(characters) / TokenEstimator.charsPerToken))
        #expect(TokenEstimator.tokens(forCharacters: characters) == expected)
        #expect(TokenEstimator.estimate(String(repeating: "a", count: characters)) == expected)
    }

    for tokens in 1...200 {
        let expected = Int(floor(Double(tokens) * TokenEstimator.charsPerToken))
        #expect(TokenEstimator.maxCharacters(forTokens: tokens) == expected)
    }

    let text = "A note with several words."
    #expect(TokenEstimator.estimate(text) == TokenEstimator.tokens(forCharacters: text.count))
}
