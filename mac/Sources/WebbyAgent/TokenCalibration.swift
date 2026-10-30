import Foundation

/// One authentic `POST /v1/messages/count_tokens` recording.
///
/// Fixtures are optional. Tests are skipped when the fixture directory is absent;
/// no count is ever invented and this source never contacts the network or stores a
/// credential. The recording procedure is the explicit maintainer step in
/// `plan.md` under "Issue #24 plan-review clarifications": read `ANTHROPIC_API_KEY`
/// from the environment, never log it, record the pinned model and API version,
/// the complete canonical request body, the returned count, the recording date and
/// provenance. That command is deliberately not committed here.
public struct TokenCalibrationFixture: Codable, Equatable, Sendable {
    public let model: String
    public let anthropicVersion: String
    public let canonicalRequestJSON: String
    public let inputTokens: Int
    public let recordedAt: String
    public let provenance: String

    public init(
        model: String,
        anthropicVersion: String,
        canonicalRequestJSON: String,
        inputTokens: Int,
        recordedAt: String,
        provenance: String
    ) {
        self.model = model
        self.anthropicVersion = anthropicVersion
        self.canonicalRequestJSON = canonicalRequestJSON
        self.inputTokens = inputTokens
        self.recordedAt = recordedAt
        self.provenance = provenance
    }
}

public enum TokenCalibration {
    public static let fixtureDirectoryName = "token-fixtures"

    public struct FixtureComparison: Equatable, Sendable {
        public let fixture: TokenCalibrationFixture
        public let estimatedTokens: Int

        public var recordedTokens: Int { fixture.inputTokens }

        public init(fixture: TokenCalibrationFixture, estimatedTokens: Int) {
            self.fixture = fixture
            self.estimatedTokens = estimatedTokens
        }
    }

    public enum Status: Equatable, Sendable {
        case skipped(reason: String)
        case recorded([FixtureComparison])
        case invalid([String])
    }

    public struct Report: Equatable, Sendable {
        public let status: Status

        public var isSkipped: Bool {
            if case .skipped = status { return true }
            return false
        }

        public init(status: Status) {
            self.status = status
        }
    }

    /// Loads fixtures from `directory`. A missing or empty directory is not an error:
    /// the helper is simply disabled and the report says so.
    public static func loadFixtures(from directory: URL?) throws -> [TokenCalibrationFixture] {
        guard let directory else { return [] }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        let decoder = JSONDecoder()
        return try names.map { name in
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            return try decoder.decode(TokenCalibrationFixture.self, from: data)
        }
    }

    /// Computes the estimator invariant for each authentic fixture. When fixtures are
    /// absent, the result is `.skipped` and no assertion is made about the constant.
    public static func check(_ fixtures: [TokenCalibrationFixture]) -> Report {
        guard !fixtures.isEmpty else {
            return Report(status: .skipped(reason: "No recorded count_tokens fixtures are present."))
        }

        var invalid: [String] = []
        var comparisons: [FixtureComparison] = []
        for fixture in fixtures {
            guard !fixture.model.isEmpty,
                  !fixture.anthropicVersion.isEmpty,
                  !fixture.canonicalRequestJSON.isEmpty,
                  !fixture.recordedAt.isEmpty,
                  !fixture.provenance.isEmpty,
                  fixture.inputTokens > 0 else {
                invalid.append("Fixture for \(fixture.model) is incomplete or has a fabricated count.")
                continue
            }
            let estimated = TokenEstimator.estimate(fixture.canonicalRequestJSON)
            guard estimated > 0 else {
                invalid.append("Estimator returned zero for \(fixture.model).")
                continue
            }
            comparisons.append(FixtureComparison(fixture: fixture, estimatedTokens: estimated))
        }

        if !invalid.isEmpty {
            return Report(status: .invalid(invalid))
        }
        return Report(status: .recorded(comparisons))
    }

    public static func check(directory: URL?) throws -> Report {
        check(try loadFixtures(from: directory))
    }
}
