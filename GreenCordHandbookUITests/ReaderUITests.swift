import XCTest

/// UI-level gates for the app as a student and as the counselor.
///
/// The app is gated behind sign-in, and these run with no server, so the suite
/// installs a session locally with `-uiTestingRole` instead of typing into the
/// sign-in form. The welcome-screen tests deliberately do not, because the point
/// of them is what an unauthenticated person can reach.
final class ReaderUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches already signed in, which is how most of these tests want the app.
    private func launch(role: String = "student") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingRole", role]
        // Deliberately does NOT forward GREENCORD_BACKEND_URL, even when the run
        // sets it for DemoRehearsalTests. The session installed here is a local
        // fake, so handing it a real server means syncing a token the server has
        // never seen - which made this suite fail only when a backend happened
        // to be configured. These tests are about the app with no server;
        // DemoRehearsalTests is the one that talks to a live one.
        app.launch()
        return app
    }

    /// Launches with no session, as a person opening the app for the first time.
    private func launchSignedOut() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        return app
    }

    /// Reach a section by searching for it.
    ///
    /// Scrolling a thirty-section list was the obvious approach and the wrong
    /// one: on an iPad's 320pt column DEADLINES is a long way down, and enough
    /// swipe-and-query rounds to get there timed the runner out. Searching is
    /// one query, is deterministic, and is how a student would actually find a
    /// section anyway.
    @discardableResult
    private func findSection(
        _ app: XCUIApplication, id: String, searching term: String
    ) -> XCUIElement {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the search field should exist")

        // Focus first. Typing into an unfocused field fails with "neither
        // element nor any descendant has keyboard focus", and tapping the clear
        // button moves focus away, so the order here matters.
        field.tap()
        if hasText(field) {
            let clear = field.buttons.firstMatch
            if clear.exists && clear.isHittable { clear.tap() }
            field.tap()
        }
        field.typeText(term)

        let hit = app.buttons["hit-\(id)"].firstMatch
        _ = hit.waitForExistence(timeout: 8)
        return hit
    }

    /// An empty SwiftUI search field reports its placeholder as its value, so a
    /// bare emptiness check would think every field already had text in it.
    private func hasText(_ field: XCUIElement) -> Bool {
        guard let value = field.value as? String else { return false }
        let placeholder = (field.placeholderValue ?? "")
        return !value.isEmpty && value != placeholder
    }

    /// Move to one of the app's sections. iPhone has a tab bar; iPad has a
    /// sidebar of navigation links.
    private func navigate(_ app: XCUIApplication, to title: String) {
        let tab = app.tabBars.buttons[title]
        if tab.waitForExistence(timeout: 3) {
            tab.tap()
            return
        }
        let sidebarLink = app.buttons[title].firstMatch
        if sidebarLink.waitForExistence(timeout: 3) {
            sidebarLink.tap()
            return
        }
        app.staticTexts[title].firstMatch.tap()
    }

    /// Opens the handbook and waits for its list of sections.
    private func openHandbook(_ app: XCUIApplication) {
        navigate(app, to: "Handbook")
        XCTAssertTrue(
            app.navigationBars["Handbook"].waitForExistence(timeout: 15)
                || app.searchFields.firstMatch.waitForExistence(timeout: 15),
            "the handbook should open"
        )
    }

    // MARK: - The gate

    func testTheAppOpensOnLogInOrCreateAccount() throws {
        let app = launchSignedOut()

        XCTAssertTrue(
            app.buttons["welcomeLogIn"].waitForExistence(timeout: 15),
            "the first screen should offer logging in"
        )
        XCTAssertTrue(
            app.buttons["welcomeCreateAccount"].exists,
            "the first screen should offer creating an account"
        )
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testNothingIsReachableBeforeSigningIn() throws {
        let app = launchSignedOut()
        XCTAssertTrue(app.buttons["welcomeLogIn"].waitForExistence(timeout: 15))

        // These are school records, so the handbook is behind the gate too.
        XCTAssertFalse(app.navigationBars["Handbook"].exists)
        XCTAssertFalse(app.otherElements["pdfReader"].exists)
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["tab-roster"].exists)
    }

    func testCreatingAnAccountRejectsACodeItCannotVerify() throws {
        let app = launchSignedOut()
        XCTAssertTrue(app.buttons["welcomeCreateAccount"].waitForExistence(timeout: 15))
        app.buttons["welcomeCreateAccount"].tap()

        let codeField = app.textFields["codeField"]
        XCTAssertTrue(
            codeField.waitForExistence(timeout: 10),
            "creating an account should start by asking for the invite code"
        )

        // The student is never asked to type their own name: it comes from the
        // code, so there is nothing here but the code itself.
        XCTAssertFalse(app.textFields["firstNameField"].exists)
        XCTAssertFalse(app.textFields["lastNameField"].exists)

        codeField.tap()
        codeField.typeText("ZZZZZZZZ")

        let submit = app.buttons["lookUpCode"]
        XCTAssertTrue(submit.isEnabled, "continuing should be possible once a code is typed")
        submit.tap()

        // With no server configured this reports the offline message rather than
        // silently doing nothing. Either way nobody is signed in.
        let error = app.staticTexts["authError"]
        XCTAssertTrue(
            error.waitForExistence(timeout: 10),
            "a code that cannot be verified must produce a visible message"
        )
        XCTAssertFalse(error.label.isEmpty)
        XCTAssertFalse(
            error.label.contains("Optional("),
            "the message should be written for a student, not a developer"
        )
        XCTAssertFalse(app.tabBars.firstMatch.exists, "no session should have been created")
    }

    func testLoggingInAsksOnlyForCredentials() throws {
        let app = launchSignedOut()
        XCTAssertTrue(app.buttons["welcomeLogIn"].waitForExistence(timeout: 15))
        app.buttons["welcomeLogIn"].tap()

        XCTAssertTrue(
            app.textFields["usernameField"].waitForExistence(timeout: 10),
            "logging in should ask for a username"
        )
        XCTAssertTrue(app.secureTextFields["passwordField"].exists)
        // Someone who already has an account should not have to find their slip.
        XCTAssertFalse(app.textFields["codeField"].exists)
    }

    // MARK: - What each role lands on

    func testAStudentLandsOnTheirOwnProgress() throws {
        let app = launch(role: "student")
        XCTAssertTrue(
            app.navigationBars["My Progress"].waitForExistence(timeout: 15)
                || app.staticTexts["My Progress"].waitForExistence(timeout: 15),
            "a student should open on their progress, not the handbook"
        )
    }

    func testAStudentSeesNoOtherStudentsData() throws {
        let app = launch(role: "student")
        XCTAssertTrue(
            app.navigationBars.firstMatch.waitForExistence(timeout: 15),
            "the app should be showing a signed-in screen"
        )

        // Neither the roster nor the review queue is reachable as a student. On
        // iPhone they are absent from the tab bar; on iPad, from the sidebar.
        XCTAssertFalse(app.buttons["tab-roster"].exists)
        XCTAssertFalse(app.buttons["tab-reviewQueue"].exists)
        XCTAssertFalse(app.staticTexts["Students"].exists)
        XCTAssertFalse(app.staticTexts["Review Queue"].exists)
    }

    func testTheCounselorReachesTheQueueAndTheRoster() throws {
        let app = launch(role: "counselor")
        XCTAssertTrue(
            app.navigationBars.firstMatch.waitForExistence(timeout: 15),
            "the app should be showing a signed-in screen"
        )

        // The counselor lands on the dashboard: how the cohort stands first,
        // then a way into each job.
        XCTAssertTrue(
            app.otherElements["counselorHome"].waitForExistence(timeout: 10)
                || app.staticTexts["to review"].waitForExistence(timeout: 10),
            "the counselor should open on the dashboard"
        )
        // A combined accessibility element does not reliably surface as any one
        // element type, so match on the identifier wherever it landed.
        for tile in ["statToReview", "statStudents", "statComplete", "statHours"] {
            let element = app.descendants(matching: .any).matching(identifier: tile).firstMatch
            XCTAssertTrue(
                element.waitForExistence(timeout: 5),
                "\(tile) should be on the dashboard"
            )
        }

        // The roster is reachable, which a student has no route to at all.
        navigate(app, to: "Students")
        XCTAssertTrue(
            app.navigationBars["Students"].waitForExistence(timeout: 10)
                || app.otherElements["rosterList"].waitForExistence(timeout: 10)
                || app.otherElements["rosterTable"].waitForExistence(timeout: 10),
            "the counselor should reach the roster"
        )

        // And so is the review queue.
        navigate(app, to: "Review Queue")
        XCTAssertTrue(
            app.navigationBars["Review Queue"].waitForExistence(timeout: 10),
            "the counselor should reach the review queue"
        )
    }

    // MARK: - The handbook

    func testTheHandbookShowsTheOriginalPages() throws {
        let app = launch()
        openHandbook(app)

        let hit = findSection(app, id: "program-overview", searching: "Program Overview")
        XCTAssertTrue(hit.exists, "the section should be findable")
        hit.tap()

        XCTAssertTrue(
            app.otherElements["pdfReader"].waitForExistence(timeout: 8)
                || app.otherElements["pdfPage"].waitForExistence(timeout: 8),
            "opening a section should show the original handbook page"
        )

        // There is no reading-mode toggle any more: the pages are the handbook.
        XCTAssertFalse(app.segmentedControls["readingModeToggle"].exists)
        XCTAssertFalse(app.otherElements["reflowedReader"].exists)
    }

    func testOpeningASectionOpensItsOwnPage() throws {
        let app = launch()
        openHandbook(app)

        let hit = findSection(
            app, id: "service-hour-requirements", searching: "Service Hour Requirements"
        )
        XCTAssertTrue(hit.exists, "the section should be findable")
        hit.tap()

        // SERVICE HOUR REQUIREMENTS starts on page 6, so that is the page the
        // reader should be sitting on rather than page 1.
        let pageLabel = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Page '")
        ).firstMatch
        XCTAssertTrue(pageLabel.waitForExistence(timeout: 8), "the page indicator should appear")
        XCTAssertTrue(
            pageLabel.label.contains("6"),
            "expected the section's own page, got \(pageLabel.label)"
        )
    }

    func testEverySectionIsReachable() throws {
        let app = launch()
        openHandbook(app)

        // Sections spread from the front of the handbook to the back, each
        // identified by the id the content pipeline generated. DEADLINES is the
        // 23rd of 30, so this reaches well past the first screenful.
        let wanted = [
            ("program-overview", "Program Overview"),
            ("service-hour-requirements", "Service Hour Requirements"),
            ("what-counts-as-community-service", "What Counts As Community Service"),
            ("deadlines", "Deadlines"),
        ]
        for (identifier, term) in wanted {
            XCTAssertTrue(
                findSection(app, id: identifier, searching: term).exists,
                "section \(identifier) should be reachable"
            )
        }
    }

    func testSearchFindsAPhraseFromTheHandbook() throws {
        let app = launch()
        openHandbook(app)

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Silver Service")

        let results = app.collectionViews["searchResults"].exists
            ? app.collectionViews["searchResults"]
            : app.tables["searchResults"]
        XCTAssertTrue(
            results.waitForExistence(timeout: 8),
            "a phrase from the handbook should return results"
        )
        XCTAssertGreaterThan(results.buttons.count, 0, "at least one hit should be listed")
    }

    func testTheHandbookWorksWithNoServerConfigured() throws {
        let app = launch()
        openHandbook(app)

        // No blocking error, no modal: the reader just works.
        XCTAssertFalse(app.alerts.firstMatch.exists, "no error dialog should block the reader")
        XCTAssertTrue(
            findSection(app, id: "program-overview", searching: "Program Overview").exists,
            "handbook content should be reachable with no server configured"
        )
    }
}
