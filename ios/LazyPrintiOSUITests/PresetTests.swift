import XCTest

// Saving the options as a preset, renaming it and deleting it from the Preset menu, on the empty Print screen.

final class PresetTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_preset_canBeSavedRenamedAndDeleted() throws {
        let app = try XCUIApplication.launched(opening: nil)

        app.openPresetMenu()
        app.item("preset.save", title: "Save as preset\u{2026}").tap()
        app.typeInAlert("Mine", replacing: "")
        XCTAssertTrue(app.openPresetMenuAndFind("Mine"), "The saved preset in the menu")

        app.item("preset.rename", title: "Rename preset").tap()
        app.presetItem("Mine").tap()
        app.typeInAlert("Yours", replacing: "Mine")
        XCTAssertTrue(app.openPresetMenuAndFind("Yours"), "The renamed preset in the menu")
        XCTAssertFalse(app.presetItem("Mine").exists, "The old name is gone")

        app.item("preset.delete", title: "Delete preset").tap()
        app.presetItem("Yours").tap()
        app.confirmButton("preset.delete.confirm", title: "Delete").tap()
        app.openPresetMenu()
        XCTAssertFalse(app.presetItem("Yours").waitForExistence(timeout: 3), "The deleted preset is gone")
    }
}

private extension XCUIApplication {
    @MainActor
    func presetItem(_ name: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    @MainActor
    func openPresetMenu() {
        let menu: XCUIElement = item("print.preset")
        XCTAssertTrue(menu.waitForExistence(timeout: 60), "The Preset menu")
        menu.tap()
    }

    /// The menu is closed by the dialog before it; opens it again, and says whether the name is in it.
    @MainActor
    func openPresetMenuAndFind(_ name: String) -> Bool {
        if presetItem(name).exists { return true }
        openPresetMenu()
        return presetItem(name).waitForExistence(timeout: 30)
    }

    /// Fills the name alert, which starts with `old` in its field, and saves.
    @MainActor
    func typeInAlert(_ name: String, replacing old: String) {
        let field: XCUIElement = alerts.firstMatch.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "The name field")
        field.tap()
        if !old.isEmpty { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        field.typeText(name)
        alerts.firstMatch.buttons["Save"].tap()
    }
}
