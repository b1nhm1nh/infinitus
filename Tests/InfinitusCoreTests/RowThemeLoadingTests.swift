import XCTest
@testable import InfinitusCore

final class RowThemeLoadingTests: XCTestCase {
    func testEveryThemedBuiltinNamesEveryPlaceholderWithAMovingIcon() {
        let motions: Set<String> = ["spin", "pulse", "bounce", "flicker"]
        for theme in RowTheme.builtins where !theme.plain {
            for key in RowTheme.plainLoadingWords.keys {
                XCTAssertNotNil(theme.loadingWords[key], "\(theme.id) lacks \(key)")
                XCTAssertNotEqual(theme.loadingWord(key), RowTheme.plainLoadingWords[key], "\(theme.id) keeps the plain \(key)")
            }
            XCTAssertTrue(theme.loadingIcon.hasPrefix("sf:"), "\(theme.id) icon \(theme.loadingIcon)")
            XCTAssertTrue(motions.contains(theme.loadingMotion), "\(theme.id) motion \(theme.loadingMotion)")
        }
    }

    func testEveryBuiltInThemeNamesTheTeamTab() {
        XCTAssertEqual(RowTheme.plainTabLabels["team"], "Team")
        XCTAssertTrue(RowTheme.plainTabIcons["team"]?.hasPrefix("sf:") == true)
        for theme in RowTheme.builtins where !theme.tabLabels.isEmpty {
            XCTAssertNotNil(theme.tabLabels["team"], "\(theme.id) names sessions/fleet/settings but not team")
            XCTAssertNotNil(theme.tabIcons["team"], "\(theme.id) lacks a team icon")
        }
    }

    func testOffAndUnthemedKeysFallBackToThePlainWords() {
        XCTAssertEqual(RowTheme.off.loadingWord("loading"), "Loading…")
        XCTAssertEqual(RowTheme.off.loadingWord("searching"), "Looking for the Mac…")
        XCTAssertEqual(RowTheme.off.loadingIcon, "")
        var partial = RowTheme.rpg
        partial.loadingWords = ["loading": "Rolling…"]
        XCTAssertEqual(partial.loadingWord("loading"), "Rolling…")
        XCTAssertEqual(partial.loadingWord("empty"), "Nothing here yet")
    }

    func testDecodeWithoutTheKeysKeepsThePlainPlaceholders() throws {
        let json = #"{"id": "x", "name": "X"}"#.data(using: .utf8)!
        let theme = try JSONDecoder().decode(RowTheme.self, from: json)
        XCTAssertTrue(theme.loadingWords.isEmpty)
        XCTAssertEqual(theme.loadingWord("noSessions"), "No live sessions")
        XCTAssertEqual(theme.loadingMotion, "")
    }

    func testTemplateCarriesThePlaceholderFields() throws {
        let themes = try JSONDecoder().decode([RowTheme].self, from: RowTheme.templateJSON.data(using: .utf8)!)
        let synth = try XCTUnwrap(themes.first)
        XCTAssertEqual(synth.loadingWord("loading"), "Booting the grid…")
        XCTAssertEqual(synth.loadingIcon, "sf:waveform")
        XCTAssertEqual(synth.loadingMotion, "pulse")
    }
}
