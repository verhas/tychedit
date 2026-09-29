import XCTest
@testable import Tychedit

@MainActor
final class TipsAndUpdateTests: XCTestCase {

    func testVersionsCompareNumerically() {
        XCTAssertTrue(UpdateChecker.isNewer("1.3.10", than: "1.3.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1", than: "1.0.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.3", than: "1.0.3"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.2", than: "1.0.3"))
        XCTAssertEqual(UpdateChecker.version(fromTag: "v1.2.3"), "1.2.3")
        XCTAssertEqual(UpdateChecker.version(fromTag: "1.2.3"), "1.2.3")
    }

    func testTipsArePlainNonEmptySentences() {
        XCTAssertGreaterThan(TycheditTips.all.count, 100)
        XCTAssertFalse(TycheditTips.all.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    func testTipsAreOnAndUpdateChecksAreOffByDefault() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.showTipsAtStartup)
        XCTAssertFalse(settings.checkForUpdates)
        XCTAssertNil(settings.lastUpdateCheck)
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }
}
