import SwiftUI

/// The first thing the app shows. Nothing in the program is reachable before
/// signing in: the handbook, a student's hours and the counselor's roster all
/// sit behind this screen.
struct WelcomeView: View {
    private enum Route: Hashable {
        case signIn
        case createAccount
        case resetPassword
    }

    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)

                    BrandLogo(size: 110)
                        .padding(.bottom, 20)

                    Text("Green Cord")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Brand.maroon)
                    Text("Princeton Senior High School")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                    Text("Community service hours, tracked and verified.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Spacer(minLength: 36)

                    VStack(spacing: 12) {
                        Button {
                            path.append(.signIn)
                        } label: {
                            Text("Log In")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("welcomeLogIn")

                        Button {
                            path.append(.createAccount)
                        } label: {
                            Text("Create Account")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("welcomeCreateAccount")

                        Text("Creating an account needs the invite code your counselor gave you.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 24)

                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity)
                // Fills the screen so the Spacers actually centre the content
                // rather than collapsing to nothing inside a ScrollView.
                .frame(minHeight: proxy.size.height)
                .padding(.horizontal, 16)
            }
            }
            .background(Brand.pageBackground)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .signIn: SignInFormView()
                case .createAccount: RedeemCodeView()
                case .resetPassword: ResetPasswordView()
                }
            }
        }
        .accessibilityIdentifier("welcomeView")
    }
}

/// Signing back in. Deliberately has no invite-code field: a student who has an
/// account should not be asked to find their slip again.
struct SignInFormView: View {
    @Environment(AppModel.self) private var model

    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var working = false

    private var isValid: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    var body: some View {
        Form {
            Section("Your sign-in details") {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .accessibilityLabel("Username")
                    .accessibilityIdentifier("usernameField")
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityLabel("Password")
                    .accessibilityIdentifier("passwordField")
            }

            if let errorMessage {
                AuthErrorRow(message: errorMessage)
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    if working {
                        SwiftUI.ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Log In").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || !isValid)
                .accessibilityLabel("Log in")
                .accessibilityIdentifier("submitAuth")
            }

            Section {
                NavigationLink("Forgot your password?") {
                    ResetPasswordView()
                }
                .accessibilityIdentifier("forgotPassword")
            } footer: {
                Text(
                    "Ask your counselor for a reset code. They can issue one without "
                    + "ever seeing your password."
                )
            }
        }
        .navigationTitle("Log In")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submit() async {
        working = true
        errorMessage = nil
        do {
            try await model.signIn(username: username, password: password)
        } catch {
            errorMessage = AuthMessages.friendly(error)
        }
        working = false
    }
}

/// Creating an account, in two steps.
///
/// The counselor issues a code to a named student, so step one asks only for the
/// code and then shows whose it is. The student confirms rather than typing a
/// name - which is what keeps the roster the counselor's own list rather than
/// whatever people enter about themselves.
struct RedeemCodeView: View {
    @Environment(AppModel.self) private var model

    @State private var code = ""
    @State private var holder: CodeHolder?
    @State private var username = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var working = false

    var body: some View {
        Form {
            if let holder {
                confirmationStep(holder)
            } else {
                codeStep
            }

            if let errorMessage {
                AuthErrorRow(message: errorMessage)
            }
        }
        .navigationTitle(holder == nil ? "Your Invite Code" : "Confirm Your Account")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Step one: the code

    @ViewBuilder
    private var codeStep: some View {
        Section {
            TextField("ABCD2345", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.title3.monospaced())
                .accessibilityLabel("Invite code from your counselor")
                .accessibilityIdentifier("codeField")
        } header: {
            Text("Invite code")
        } footer: {
            Text(
                "Your counselor issues one code per student. Codes are eight characters "
                + "and contain no letter O or number 0."
            )
        }

        Section {
            Button {
                Task { await lookUp() }
            } label: {
                if working {
                    SwiftUI.ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Continue").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(working || code.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Continue with this invite code")
            .accessibilityIdentifier("lookUpCode")
        }
    }

    private func lookUp() async {
        working = true
        errorMessage = nil
        do {
            holder = try await model.lookupCode(code)
        } catch {
            errorMessage = AuthMessages.friendly(error)
        }
        working = false
    }

    // MARK: - Step two: confirm and set a password

    @ViewBuilder
    private func confirmationStep(_ holder: CodeHolder) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(holder.fullName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Brand.maroon)
                Text("Grade \(holder.grade)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("This code is for \(holder.fullName), grade \(holder.grade)")
            .accessibilityIdentifier("codeHolder")
        } header: {
            Text("This code is for")
        } footer: {
            Text(
                "Your counselor set this. If the name or grade is wrong, stop here and "
                + "tell them - do not use someone else's code."
            )
        }

        Section {
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Choose a username")
                .accessibilityIdentifier("usernameField")
            SecureField("Password", text: $password)
                .accessibilityLabel("Choose a password, at least eight characters")
                .accessibilityIdentifier("passwordField")
            SecureField("Password again", text: $confirmPassword)
                .accessibilityLabel("Type your password again")
                .accessibilityIdentifier("confirmPasswordField")
        } header: {
            Text("Set up your sign-in")
        } footer: {
            Text("At least eight characters. You will use this every time you open the app.")
        }

        Section {
            Button {
                Task { await createAccount() }
            } label: {
                if working {
                    SwiftUI.ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Create My Account").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(working || !credentialsReady)
            .accessibilityLabel("Create my account")
            .accessibilityIdentifier("submitAuth")

            Button("This is not me") {
                self.holder = nil
                errorMessage = nil
            }
            .accessibilityLabel("Go back and enter a different code")
            .accessibilityIdentifier("wrongPerson")
        }
    }

    private var credentialsReady: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && password.count >= 8
            && password == confirmPassword
    }

    private func createAccount() async {
        working = true
        errorMessage = nil
        do {
            try await model.redeem(code: code, username: username, password: password)
        } catch {
            errorMessage = AuthMessages.friendly(error)
        }
        working = false
    }
}

/// Setting a new password with a code from a counselor.
///
/// There is no email server behind the prototype, so a reset travels the way an
/// invite does: an admin issues a one-time code and hands it over. Redeeming it
/// signs every existing session out, because a reset exists for the case where
/// someone else may have had the old password.
struct ResetPasswordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var done = false
    @State private var working = false

    private var isValid: Bool {
        !code.trimmingCharacters(in: .whitespaces).isEmpty
            && password.count >= 8
            && password == confirmPassword
    }

    var body: some View {
        Form {
            if done {
                Section {
                    Label(
                        "Your password is set. Go back and log in with it.",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(Brand.cordGreen)
                    .accessibilityIdentifier("resetDone")

                    Button("Back to log in") { dismiss() }
                        .accessibilityIdentifier("backToLogIn")
                }
            } else {
                Section {
                    TextField("ABCD2345", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.title3.monospaced())
                        .accessibilityLabel("The reset code from your counselor")
                        .accessibilityIdentifier("resetCodeField")
                } header: {
                    Text("Reset code")
                } footer: {
                    Text("Your counselor issues this. It works once and lasts two days.")
                }

                Section {
                    SecureField("New password", text: $password)
                        .accessibilityLabel("Your new password, at least eight characters")
                        .accessibilityIdentifier("newPasswordField")
                    SecureField("New password again", text: $confirmPassword)
                        .accessibilityLabel("Type your new password again")
                        .accessibilityIdentifier("confirmNewPasswordField")
                } footer: {
                    Text("At least eight characters.")
                }

                if let errorMessage { AuthErrorRow(message: errorMessage) }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if working {
                            SwiftUI.ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Set My Password").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || !isValid)
                    .accessibilityLabel("Set my password")
                    .accessibilityIdentifier("submitReset")
                }
            }
        }
        .navigationTitle("New Password")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submit() async {
        working = true
        errorMessage = nil
        do {
            try await model.resetPassword(code: code, password: password)
            done = true
        } catch {
            errorMessage = AuthMessages.friendly(error)
        }
        working = false
    }
}

/// One place for the wording, so sign-in and sign-up cannot drift apart.
enum AuthMessages {
    /// Server error codes turned into something a 14-year-old can act on.
    static func friendly(_ error: Error) -> String {
        guard let apiError = error as? APIError else { return error.localizedDescription }
        switch apiError.code {
        case "code_unknown":
            return "We do not recognise that code. Check it and try again - codes have no letter O or number 0."
        case "code_used":
            return "That code has already been used. Ask your counselor for a new one."
        case "code_expired":
            return "That code has expired. Ask your counselor for a new one."
        case "code_revoked":
            return "That code was cancelled. Ask your counselor for a new one."
        case "code_missing":
            return "Enter the code your counselor gave you."
        case "password_short":
            return "Pick a password of at least 8 characters."
        case "username_taken":
            return "Someone already uses that username. Try another."
        case "bad_credentials":
            return "That username and password do not match."
        case "offline":
            return "You are offline. Try again once you have a connection."
        default:
            return apiError.message
        }
    }
}

struct AuthErrorRow: View {
    let message: String

    var body: some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.callout)
                .accessibilityIdentifier("authError")
        }
    }
}

#if DEBUG
#Preview("Welcome") {
    WelcomeView().environment(PreviewData.model).tint(Brand.maroon)
}

#Preview("Log in") {
    NavigationStack { SignInFormView() }
        .environment(PreviewData.model)
        .tint(Brand.maroon)
}

#Preview("Redeem a code") {
    NavigationStack { RedeemCodeView() }
        .environment(PreviewData.model)
        .tint(Brand.maroon)
}
#endif
