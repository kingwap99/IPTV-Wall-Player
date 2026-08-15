import XCTest

final class FocusNavigationTests: XCTestCase {
    func testImportLargeM3UPlaylistPersists() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-category", "m3u",
            "-mode", "4×4",
            "--seed-favorites-for-ui-testing",
            "--import-m3u-url=https://iptv-org.github.io/iptv/index.m3u"
        ]
        app.launch()

        let manageButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '1 份清單'")
        ).firstMatch
        XCTAssertTrue(manageButton.waitForExistence(timeout: 120))
    }

    func testRemoteCanMoveFromFavoritesHeroToMiniChannel() throws {
        let app = launchFavoritesApp()

        let favoritesButton = app.buttons["我的最愛"]
        XCTAssertTrue(favoritesButton.waitForExistence(timeout: 30))
        let heroFocused = expectation(
            for: NSPredicate(format: "hasFocus == true"),
            evaluatedWith: favoritesButton
        )
        XCTAssertTrue(
            XCTWaiter.wait(for: [heroFocused], timeout: 30) == .completed
        )

        XCUIRemote.shared.press(.up)

        let firstCenterButton = app.buttons.matching(NSPredicate(format: "label == '置中'")).firstMatch
        let miniChannelFocused = expectation(
            for: NSPredicate(format: "hasFocus == true"),
            evaluatedWith: firstCenterButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [miniChannelFocused], timeout: 5), .completed)

        let focusedMiniChannel = XCTAttachment(screenshot: app.screenshot())
        focusedMiniChannel.name = "Focused mini channel uses yellow border"
        focusedMiniChannel.lifetime = .keepAlways
        add(focusedMiniChannel)
    }

    func testRemoteWakesControlsAfterIdleTimeout() throws {
        let app = launchFavoritesApp()
        let favoritesButton = app.buttons["我的最愛"]
        XCTAssertTrue(favoritesButton.waitForExistence(timeout: 30))

        let hidden = expectation(
            for: NSPredicate(format: "value == 'controls-hidden'"),
            evaluatedWith: favoritesButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 15), .completed)

        XCUIRemote.shared.press(.right)

        let visibleAgain = expectation(
            for: NSPredicate(format: "value == 'controls-visible'"),
            evaluatedWith: favoritesButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [visibleAgain], timeout: 5), .completed)
    }

    func testUnfavoriteRequiresConfirmation() throws {
        let app = launchFavoritesApp(focusUnfavorite: true)
        let pinnedButton = app.buttons["★ 已釘選"]
        XCTAssertTrue(pinnedButton.waitForExistence(timeout: 30))

        let pinnedButtonFocused = expectation(
            for: NSPredicate(format: "hasFocus == true"),
            evaluatedWith: pinnedButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [pinnedButtonFocused], timeout: 30), .completed)

        XCUIRemote.shared.press(.select)

        let confirmation = app.alerts["取消釘選？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.buttons["保留"].exists)
        XCTAssertTrue(confirmation.buttons["取消釘選"].exists)
    }

    func testAdjacentMiniChannelMovesDirectlyIntoHero() throws {
        let app = launchFavoritesApp(miniFocusIndex: 1)
        let secondCenterButton = app.buttons.matching(NSPredicate(format: "label == '置中'")).element(boundBy: 1)
        XCTAssertTrue(secondCenterButton.waitForExistence(timeout: 30))

        let miniFocused = expectation(
            for: NSPredicate(format: "hasFocus == true"),
            evaluatedWith: secondCenterButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [miniFocused], timeout: 30), .completed)

        XCUIRemote.shared.press(.down)

        let favoritesButton = app.buttons["我的最愛"]
        let heroFocused = expectation(
            for: NSPredicate(format: "hasFocus == true"),
            evaluatedWith: favoritesButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [heroFocused], timeout: 5), .completed)

        let focusedHero = XCTAttachment(screenshot: app.screenshot())
        focusedHero.name = "Focused hero uses yellow border"
        focusedHero.lifetime = .keepAlways
        add(focusedHero)
    }

    func testLongPressMiniShowsActionMenuWithoutMovingTile() throws {
        let app = launchFavoritesApp(miniFocusIndex: 0)
        let focusedMini = app.buttons.matching(
            NSPredicate(format: "hasFocus == true")
        ).firstMatch
        XCTAssertTrue(focusedMini.waitForExistence(timeout: 30))
        let focusedMiniIdentifier = focusedMini.identifier
        XCTAssertTrue(focusedMiniIdentifier.hasPrefix("mini-channel-"))
        let stableMini = app.buttons[focusedMiniIdentifier]

        let frameBeforeLongPress = stableMini.frame
        XCUIRemote.shared.press(.select, forDuration: 0.9)

        XCTAssertTrue(app.buttons["調整頻道位置"].waitForExistence(timeout: 5))
        XCTAssertTrue(stableMini.exists)
        let frameAfterLongPress = stableMini.frame
        XCTAssertEqual(frameAfterLongPress.midX, frameBeforeLongPress.midX, accuracy: 0.5)
        XCTAssertEqual(frameAfterLongPress.midY, frameBeforeLongPress.midY, accuracy: 0.5)
        XCTAssertLessThanOrEqual(abs(frameAfterLongPress.width - frameBeforeLongPress.width), 12)
        XCTAssertLessThanOrEqual(abs(frameAfterLongPress.height - frameBeforeLongPress.height), 12)

        let stableMenu = XCTAttachment(screenshot: app.screenshot())
        stableMenu.name = "Long press menu does not lift the live mini tile"
        stableMenu.lifetime = .keepAlways
        add(stableMenu)
    }

    private func launchFavoritesApp(focusUnfavorite: Bool = false, miniFocusIndex: Int? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-category", "favorites",
            "-mode", "4×4",
            "--seed-favorites-for-ui-testing",
            "--force-hero-focus-for-ui-testing"
        ]
        if focusUnfavorite {
            app.launchArguments.append("--force-unfavorite-focus-for-ui-testing")
        }
        if let miniFocusIndex {
            app.launchArguments.append("--force-mini-focus-index-for-ui-testing=\(miniFocusIndex)")
        }
        app.launch()
        return app
    }
}
