import XCTest

final class PadEditingTests: XCTestCase {
    @MainActor
    func testCreateEditRepairAndReopenDocument() throws {
        let app = XCUIApplication()
        app.launch()
        let landingCreate = app.buttons["Create Document"]
        if landingCreate.waitForExistence(timeout: 5) {
            landingCreate.tap()
        } else {
            let sidebar = app.buttons["ToggleSidebar"]
            if sidebar.waitForExistence(timeout: 15) { sidebar.tap() }
            let local = app.cells["DOC.sidebar.item.On My iPad"]
            if local.waitForExistence(timeout: 3) { local.tap() }
            let create = app.buttons["FullDocumentManagerViewControllerNavigationBarCreateButtonIdentifier"]
            XCTAssertTrue(create.waitForExistence(timeout: 30), app.debugDescription)
            create.tap()
        }

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 30), app.debugDescription)
        replaceText(in: editor, app: app, with: "digraph { a -> b }")
        XCTAssertTrue(app.buttons["a"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["No problems"].waitForExistence(timeout: 10))

        replaceText(in: editor, app: app, with: "digraph { a -> b")
        let repair = app.buttons["Insert “}”"]
        XCTAssertTrue(repair.waitForExistence(timeout: 10), app.debugDescription)
        repair.tap()
        XCTAssertTrue(app.staticTexts["No problems"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(editor.value as? String, "digraph { a -> b}")

        let title = (app.navigationBars.firstMatch.identifier as NSString).deletingPathExtension
        app.navigationBars.buttons.firstMatch.tap()
        let saved = app.cells[title + ", dot"]
        XCTAssertTrue(saved.waitForExistence(timeout: 15), app.debugDescription)
        saved.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, "digraph { a -> b}")
    }

    @MainActor
    private func replaceText(in editor: XCUIElement, app: XCUIApplication, with text: String) {
        editor.tap()
        editor.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 3) { selectAll.tap() }
        editor.typeText(text)
    }
}
