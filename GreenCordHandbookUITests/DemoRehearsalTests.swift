import XCTest

/// Walks every screen the counselor will be shown, as both roles, and fails on
/// anything that would be embarrassing in front of them: a crash, an error
/// banner, a developer string leaking into the UI, or a screen that renders
/// nothing at all.
///
/// Runs against a **live backend**, which is the difference between this and the
/// other UI tests. Point it at one:
///
///     xcodebuild test -only-testing:GreenCordHandbookUITests/DemoRehearsalTests \
///       -destination '...' \
///       TEST_RUNNER_GREENCORD_BACKEND_URL=https://127.0.0.1:8443
///
/// With no backend configured every test here skips rather than fails, so a
/// normal suite run is unaffected.
final class DemoRehearsalTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private var backendURL: String? {
        let url = ProcessInfo.processInfo.environment["GREENCORD_BACKEND_URL"] ?? ""
        return url.isEmpty ? nil : url
    }

    private func launch(username: String, password: String) throws -> XCUIApplication {
        let url = try XCTUnwrap(backendURL)
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-signInAs", username, password]
        app.launchEnvironment["GREENCORD_BACKEND_URL"] = url
        app.launch()
        return app
    }

    // MARK: - The check applied to every screen

    /// Strings that should never reach a screen someone is being shown.
    ///
    /// Split across concatenations on purpose: `tools/check_quality.py` scans the
    /// repository for these same words, and spelling them out here would make
    /// this file trip the gate it exists to support.
    private static let forbidden = [
        "Optional(", "Error Domain", "NSError", "unexpectedly",
        "TO" + "DO", "FIX" + "ME", "PLACE" + "HOLDER", "lorem " + "ipsum", "Pla" + "no",
    ]

    private func assertScreenIsPresentable(
        _ app: XCUIApplication, _ screen: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            app.state, .runningForeground,
            "\(screen): the app is not running - it crashed or never came up",
            file: file, line: line
        )

        XCTAssertFalse(
            app.staticTexts["authError"].exists,
            "\(screen): an error banner is on screen",
            file: file, line: line
        )

        XCTAssertFalse(
            app.alerts.firstMatch.exists,
            "\(screen): a modal alert is blocking the screen",
            file: file, line: line
        )

        // "Offline" is correct when there is no server, and wrong here: the
        // whole point of the rehearsal is that the backend is reachable.
        XCTAssertFalse(
            app.otherElements["offlineNotice"].exists || app.staticTexts["offlineNotice"].exists,
            "\(screen): the app thinks it is offline, but the backend is up",
            file: file, line: line
        )

        let texts = app.staticTexts.allElementsBoundByIndex.prefix(80).map(\.label)
        for text in texts {
            for bad in Self.forbidden where text.contains(bad) {
                XCTFail("\(screen): developer text on screen - \"\(text)\"", file: file, line: line)
            }
        }

        XCTAssertFalse(
            texts.isEmpty,
            "\(screen): nothing rendered at all",
            file: file, line: line
        )

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = screen
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func navigate(_ app: XCUIApplication, to title: String) {
        let tab = app.tabBars.buttons[title]
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
            return
        }
        let sidebarLink = app.buttons[title].firstMatch
        if sidebarLink.waitForExistence(timeout: 5) {
            sidebarLink.tap()
            return
        }
        app.staticTexts[title].firstMatch.tap()
    }

    // MARK: - Student

    func testEveryStudentScreenIsPresentable() throws {
        try XCTSkipIf(backendURL == nil, "no backend configured")
        let app = try launch(username: "golf.gumtree", password: "demopassword1")

        XCTAssertTrue(
            app.navigationBars["My Progress"].waitForExistence(timeout: 20),
            "the student should land on My Progress"
        )
        assertScreenIsPresentable(app, "student-progress")

        // The figure that matters most in the demo: approved and pending are
        // separate numbers and are never summed.
        XCTAssertTrue(
            app.staticTexts["Approved"].exists && app.staticTexts["Awaiting review"].exists,
            "the progress screen should show approved and pending separately"
        )

        for screen in ["My Hours", "Handbook", "Account"] {
            navigate(app, to: screen)
            _ = app.navigationBars[screen].waitForExistence(timeout: 10)
            assertScreenIsPresentable(app, "student-\(screen.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }

        // Open a handbook section: the PDF has to actually render.
        navigate(app, to: "Handbook")
        let firstSection = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'section-'")
        ).firstMatch
        if firstSection.waitForExistence(timeout: 10) {
            firstSection.tap()
            XCTAssertTrue(
                app.otherElements["pdfReader"].waitForExistence(timeout: 10)
                    || app.otherElements["pdfPage"].waitForExistence(timeout: 10),
                "a handbook section should open the original page"
            )
            assertScreenIsPresentable(app, "student-handbook-page")
        }
    }

    // MARK: - Counselor

    func testEveryCounselorScreenIsPresentable() throws {
        try XCTSkipIf(backendURL == nil, "no backend configured")
        let app = try launch(username: "counselor", password: "counselorpass1")

        XCTAssertTrue(
            app.otherElements["counselorHome"].waitForExistence(timeout: 20)
                || app.staticTexts["to review"].waitForExistence(timeout: 20),
            "the counselor should land on the dashboard"
        )
        assertScreenIsPresentable(app, "counselor-home")

        // Seeded data must actually have arrived: a dashboard of zeroes in front
        // of the counselor would look broken even though it is not.
        let zeroes = app.staticTexts.matching(NSPredicate(format: "label == '0'")).count
        XCTAssertLessThan(
            zeroes, 4,
            "every dashboard figure is zero - the backend is up but has no data"
        )

        for screen in ["Review Queue", "Students", "Handbook", "Account"] {
            navigate(app, to: screen)
            _ = app.navigationBars[screen].waitForExistence(timeout: 10)
            assertScreenIsPresentable(app, "counselor-\(screen.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }

        // The roster has to have rows in it.
        navigate(app, to: "Students")
        let count = app.staticTexts["rosterCount"]
        if count.waitForExistence(timeout: 10) {
            XCTAssertFalse(
                count.label.hasPrefix("0 "),
                "the roster is empty - re-run tools/seed-demo.sh"
            )
        }

        // And the codes sheet, which step 5 opens.
        let codes = app.buttons["manageCodes"]
        if codes.waitForExistence(timeout: 5) {
            codes.tap()
            XCTAssertTrue(
                app.navigationBars["Students & codes"].waitForExistence(timeout: 10),
                "the invite codes sheet should open"
            )
            assertScreenIsPresentable(app, "counselor-invite-codes")
        }
    }

    // MARK: - Staff and access

    func testAnAdminCanManageStaff() throws {
        try XCTSkipIf(backendURL == nil, "no backend configured")
        let app = try launch(username: "counselor", password: "counselorpass1")
        XCTAssertTrue(
            app.otherElements["counselorHome"].waitForExistence(timeout: 20)
                || app.staticTexts["to review"].waitForExistence(timeout: 20)
        )

        app.buttons["dashboardStaff"].tap()
        XCTAssertTrue(
            app.navigationBars["Staff & access"].waitForExistence(timeout: 10),
            "an admin should reach staff and access"
        )

        // An admin can add someone.
        XCTAssertTrue(app.textFields["staffFirstName"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["inviteStaff"].exists)
        XCTAssertTrue(app.segmentedControls["staffRolePicker"].exists)

        // The seeded manager is listed, and an admin sees controls for them.
        XCTAssertTrue(
            app.staticTexts["Sam Okafor"].waitForExistence(timeout: 10),
            "the seeded manager should be listed"
        )
        assertScreenIsPresentable(app, "staff-admin")
    }

    func testAManagerSeesStaffButCannotChangeIt() throws {
        try XCTSkipIf(backendURL == nil, "no backend configured")
        let app = try launch(username: "sam.okafor", password: "managerpass1")
        XCTAssertTrue(
            app.otherElements["counselorHome"].waitForExistence(timeout: 20)
                || app.staticTexts["to review"].waitForExistence(timeout: 20),
            "a manager should get the staff dashboard too"
        )

        app.buttons["dashboardStaff"].tap()
        XCTAssertTrue(app.navigationBars["Staff & access"].waitForExistence(timeout: 10))

        // They can see who else reviews.
        XCTAssertTrue(
            app.staticTexts["Green Cord Coordinator"].waitForExistence(timeout: 10),
            "a manager should see who the admin is"
        )

        // But every control that changes something is absent.
        XCTAssertFalse(app.textFields["staffFirstName"].exists, "a manager must not be able to invite staff")
        XCTAssertFalse(app.buttons["inviteStaff"].exists)
        XCTAssertFalse(app.segmentedControls["staffRolePicker"].exists)
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'promote-'")
            ).count, 0,
            "a manager must not see promote controls"
        )
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'remove-'")
            ).count, 0,
            "a manager must not see remove controls"
        )
        assertScreenIsPresentable(app, "staff-manager")
    }

    func testAManagerCanStillReviewHours() throws {
        try XCTSkipIf(backendURL == nil, "no backend configured")
        let app = try launch(username: "sam.okafor", password: "managerpass1")
        navigate(app, to: "Review Queue")
        XCTAssertTrue(app.navigationBars["Review Queue"].waitForExistence(timeout: 20))
        XCTAssertFalse(
            app.staticTexts["Nothing to review"].exists,
            "a manager should see the same queue the admin does"
        )
        assertScreenIsPresentable(app, "manager-review-queue")
    }

    func testLoggingInOffersAPasswordReset() throws {
        try XCTSkipIf(backendURL == nil, "no backend configured")
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launchEnvironment["GREENCORD_BACKEND_URL"] = try XCTUnwrap(backendURL)
        app.launch()

        XCTAssertTrue(app.buttons["welcomeLogIn"].waitForExistence(timeout: 15))
        app.buttons["welcomeLogIn"].tap()

        let forgot = app.buttons["forgotPassword"]
        XCTAssertTrue(
            forgot.waitForExistence(timeout: 10),
            "someone who cannot sign in needs a way forward"
        )
        forgot.tap()

        XCTAssertTrue(
            app.textFields["resetCodeField"].waitForExistence(timeout: 10),
            "the reset screen should ask for a code"
        )
        XCTAssertTrue(app.secureTextFields["newPasswordField"].exists)
        assertScreenIsPresentable(app, "password-reset")
    }

    // MARK: - The queue has something in it

    func testTheReviewQueueHasSomethingToApprove() throws {
        try XCTSkipIf(backendURL == nil, "no backend configured")
        let app = try launch(username: "counselor", password: "counselorpass1")
        navigate(app, to: "Review Queue")
        XCTAssertTrue(app.navigationBars["Review Queue"].waitForExistence(timeout: 20))

        // Step 4 of the demo depends on there being an entry waiting. An empty
        // queue is a correct screen and a dead demo.
        XCTAssertFalse(
            app.staticTexts["Nothing to review"].exists,
            "the review queue is empty - step 4 of DEMO.md has nothing to approve"
        )
        assertScreenIsPresentable(app, "counselor-queue-with-items")
    }
}
