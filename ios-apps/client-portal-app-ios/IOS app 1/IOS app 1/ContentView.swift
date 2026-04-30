//
//  ContentView.swift
//  IOS app 1
//
//  Created by Grant Corp on 3/29/26.
//

import SwiftUI
import WebKit

private let portalLogoURL = URL(string: "https://github.com/Corptech02/website-V3/blob/main/images/vanguard-logo.png?raw=true")

struct ContentView: View {
    @State private var session = PortalSessionStore()
    @State private var email = ""
    @State private var password = ""
    @State private var rememberMe = true

    var body: some View {
        Group {
            if session.isAuthenticated {
                PortalHomeView(
                    session: session,
                    onLogout: {
                        session.logout()
                    }
                )
            } else {
                LoginView(
                    email: $email,
                    password: $password,
                    rememberMe: $rememberMe,
                    errorMessage: session.errorMessage,
                    isLoading: session.isLoading,
                    onLogin: handleLogin,
                    onForgotPassword: handleForgotPassword
                )
            }
        }
        .task {
            await session.bootstrap()
        }
        .sheet(isPresented: needsPasswordSetupBinding) {
            CreatePasswordView(
                email: setupEmail,
                errorMessage: session.errorMessage,
                isLoading: session.isLoading,
                onSubmit: { newPassword in
                    Task {
                        _ = await session.setupPassword(email: setupEmail, newPassword: newPassword)
                    }
                },
                onCancel: {
                    session.loginFlowState = .idle
                }
            )
        }
        .sheet(isPresented: needsPasswordResetBinding) {
            PasswordResetView(
                email: resetEmail,
                resetToken: resetToken,
                errorMessage: session.errorMessage,
                isLoading: session.isLoading,
                onRequestToken: {
                    Task {
                        await session.requestPasswordReset(email: resetEmail)
                    }
                },
                onSubmit: { token, newPassword in
                    Task {
                        _ = await session.completePasswordReset(
                            email: resetEmail,
                            resetToken: token,
                            newPassword: newPassword
                        )
                    }
                },
                onCancel: {
                    session.loginFlowState = .idle
                }
            )
        }
        .animation(.snappy, value: session.isAuthenticated)
    }

    private func handleLogin() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            return
        }

        Task {
            _ = await session.login(email: trimmedEmail, password: password)
        }
    }

    private func handleForgotPassword() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }
        Task {
            await session.requestPasswordReset(email: trimmedEmail)
        }
    }

    private var needsPasswordSetupBinding: Binding<Bool> {
        Binding(
            get: {
                if case .needsPasswordSetup = session.loginFlowState {
                    return true
                }
                return false
            },
            set: { newValue in
                if !newValue {
                    session.loginFlowState = .idle
                }
            }
        )
    }

    private var setupEmail: String {
        if case let .needsPasswordSetup(email) = session.loginFlowState {
            return email
        }
        return email
    }

    private var needsPasswordResetBinding: Binding<Bool> {
        Binding(
            get: {
                if case .needsPasswordReset = session.loginFlowState {
                    return true
                }
                return false
            },
            set: { newValue in
                if !newValue {
                    session.loginFlowState = .idle
                }
            }
        )
    }

    private var resetEmail: String {
        if case let .needsPasswordReset(email, _) = session.loginFlowState {
            return email
        }
        return email
    }

    private var resetToken: String? {
        if case let .needsPasswordReset(_, token) = session.loginFlowState {
            return token
        }
        return nil
    }
}

private struct LoginView: View {
    @Binding var email: String
    @Binding var password: String
    @Binding var rememberMe: Bool
    let errorMessage: String?
    let isLoading: Bool
    let onLogin: () -> Void
    let onForgotPassword: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.12, blue: 0.24), Color(red: 0.08, green: 0.39, blue: 0.54)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        LogoBannerView(url: portalLogoURL, height: 98)

                        Text("Client Portal")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.92))

                        Text("Review policies, request certificates, and manage your profile after sign in.")
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.75))
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        PortalTextField(title: "Email", text: $email, usesEmailKeyboard: true, style: .light)
                        PortalSecureField(title: "Password", text: $password, style: .light)

                        Toggle("Keep me signed in", isOn: $rememberMe)
                            .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.19, green: 0.78, blue: 0.64)))
                            .foregroundStyle(Color.white.opacity(0.88))

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.82))
                        }

                        Button(action: onLogin) {
                            Text(isLoading ? "Signing In..." : "Sign In")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color.white)
                                .foregroundStyle(Color(red: 0.04, green: 0.12, blue: 0.24))
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .disabled(isLoading)

                        Button("Forgot Password?", action: onForgotPassword)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 8) {
                            Label("Policy summaries", systemImage: "checkmark.shield.fill")
                            Label("Digital ID cards", systemImage: "doc.text.fill")
                            Label("Certificate requests", systemImage: "envelope.badge.shield.half.filled")
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                    }
                    .padding(24)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
                .padding(24)
                .frame(maxWidth: 430)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct PasswordResetView: View {
    let email: String
    let resetToken: String?
    let errorMessage: String?
    let isLoading: Bool
    let onRequestToken: () -> Void
    let onSubmit: (String, String) -> Void
    let onCancel: () -> Void

    @State private var tokenInput = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var localError: String?

    var body: some View {
        AuthFlowContainer(
            title: "Reset Password",
            subtitle: "Request a token, set a new password, and sign back into the portal.",
            email: email
        ) {
            if let resetToken, !resetToken.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reset Token")
                        .font(.headline)
                    Text(resetToken)
                        .font(.footnote.monospaced())
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            PortalTextField(title: "Reset Token", text: $tokenInput)
            PortalSecureField(title: "New Password", text: $newPassword)
            PortalSecureField(title: "Confirm Password", text: $confirmPassword)

            if let message = localError ?? errorMessage {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
            }

            Button("Request New Reset Token", action: onRequestToken)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.03, green: 0.34, blue: 0.55))
                .buttonStyle(.plain)

            Button {
                guard !tokenInput.isEmpty || !(resetToken?.isEmpty ?? true) else {
                    localError = "Enter the reset token."
                    return
                }
                guard newPassword.count >= 8 else {
                    localError = "Password must be at least 8 characters."
                    return
                }
                guard newPassword == confirmPassword else {
                    localError = "Passwords do not match."
                    return
                }
                localError = nil
                onSubmit(tokenInput.isEmpty ? (resetToken ?? "") : tokenInput, newPassword)
            } label: {
                AuthPrimaryButtonLabel(title: isLoading ? "Resetting..." : "Reset Password")
            }
            .disabled(isLoading)

            Button("Cancel", action: onCancel)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.white)
                .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .onAppear {
            if tokenInput.isEmpty, let resetToken {
                tokenInput = resetToken
            }
        }
    }
}

private struct CreatePasswordView: View {
    let email: String
    let errorMessage: String?
    let isLoading: Bool
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var localError: String?

    var body: some View {
        AuthFlowContainer(
            title: "Create Password",
            subtitle: "Set your first portal password and continue straight into your client account.",
            email: email
        ) {
            PortalSecureField(title: "New Password", text: $newPassword)
            PortalSecureField(title: "Confirm Password", text: $confirmPassword)

            if let message = localError ?? errorMessage {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
            }

            Button {
                guard newPassword.count >= 8 else {
                    localError = "Password must be at least 8 characters."
                    return
                }
                guard newPassword == confirmPassword else {
                    localError = "Passwords do not match."
                    return
                }
                localError = nil
                onSubmit(newPassword)
            } label: {
                AuthPrimaryButtonLabel(title: isLoading ? "Creating..." : "Create Password")
            }
            .disabled(isLoading)

            Button("Cancel", action: onCancel)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.white)
                .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct AuthFlowContainer<Content: View>: View {
    let title: String
    let subtitle: String
    let email: String
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    LogoBannerView(url: portalLogoURL, height: 78)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.title2.bold())
                            .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))

                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0.33, green: 0.40, blue: 0.49))

                        Text(email)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(red: 0.03, green: 0.34, blue: 0.55))
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        content
                    }
                    .padding(22)
                    .background(Color(red: 0.96, green: 0.98, blue: 1.0))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .padding(24)
                .frame(maxWidth: 430)
                .frame(maxWidth: .infinity)
            }
            .background(Color(red: 0.92, green: 0.96, blue: 0.99))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct AuthPrimaryButtonLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Color(red: 0.03, green: 0.34, blue: 0.55))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct PortalHomeView: View {
    let session: PortalSessionStore
    @State private var selectedPolicyID = SamplePortalData.policies[0].id
    @State private var presentedDocument: PolicyDocumentPresentation?
    @State private var presentedLibraryDocument: DocumentLibraryPresentation?
    @State private var requestPolicy: PolicySummary?
    let onLogout: () -> Void

    private var profile: PortalProfile {
        session.profile ?? SamplePortalData.profile
    }

    private var policies: [PolicySummary] {
        session.policies
    }

    private var documents: [PortalDocument] {
        SamplePortalData.documents
    }

    var body: some View {
        TabView {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerCard
                        policySection
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 430)
                    .frame(maxWidth: .infinity)
                }
                .background(Color(red: 0.89, green: 0.93, blue: 0.97))
                .navigationTitle("Dashboard")
                .toolbar {
                    ToolbarItem {
                        Button("Logout", action: onLogout)
                    }
                }
            }
            .tabItem {
                Label("Home", systemImage: "square.grid.2x2.fill")
            }

            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        documentsSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 430)
                    .frame(maxWidth: .infinity)
                }
                .background(Color(red: 0.84, green: 0.90, blue: 0.95))
                .navigationTitle("Documents")
            }
            .tabItem {
                Label("Documents", systemImage: "doc.text.fill")
            }

            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        profileCard(profile: profile)
                        accountDetails
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 430)
                    .frame(maxWidth: .infinity)
                }
                .background(Color(red: 0.89, green: 0.93, blue: 0.97))
                .navigationTitle("Profile")
            }
            .tabItem {
                Label("Profile", systemImage: "person.crop.circle.fill")
            }
        }
        .tint(Color(red: 0.03, green: 0.34, blue: 0.55))
        .fullScreenCover(item: $presentedDocument) { document in
            PolicyDocumentViewer(document: document, session: session)
        }
        .fullScreenCover(item: $presentedLibraryDocument) { document in
            DocumentLibraryViewer(document: document, policies: policies, session: session)
        }
        .sheet(item: $requestPolicy) { policy in
            CertificateRequestSheet(policy: policy, session: session)
        }
        .onAppear(perform: syncSelectedPolicy)
        .onChange(of: session.policies.map(\.id)) { _, _ in
            syncSelectedPolicy()
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            LogoBannerView(url: portalLogoURL, height: 88)

            Text("Welcome back, \(profile.firstName)")
                .font(.title.bold())
                .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))

            Text("Manage your active commercial policies, billing, and client requests from one place.")
                .font(.subheadline)
                .foregroundStyle(Color(red: 0.29, green: 0.36, blue: 0.45))

            WideStatBar(title: "Active Policies", value: "\(policies.count)", icon: "shield.fill")
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.96, green: 0.98, blue: 1.0), Color(red: 0.80, green: 0.90, blue: 0.98)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var policySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("My Policies")

            if policies.isEmpty {
                EmptyPoliciesCard()
            } else {
                ForEach(policies) { policy in
                    PolicyCard(
                        policy: policy,
                        isSelected: policy.id == selectedPolicyID,
                        onSelect: {
                            selectedPolicyID = policy.id
                        },
                    onRequestCOI: {
                        requestPolicy = policy
                    },
                    onViewCOI: {
                        Task {
                            await session.refreshDocuments(for: policy)
                            if let liveDocument = session.firstDocument(for: policy, matching: "coi") {
                                presentedDocument = .live(policy, kind: .coi, serverDocument: liveDocument)
                            } else {
                                presentedDocument = .coi(policy)
                            }
                        }
                    },
                    onViewIDCards: {
                        Task {
                            await session.refreshDocuments(for: policy)
                            if let liveDocument = session.firstDocument(for: policy, matching: "id_card") {
                                presentedDocument = .live(policy, kind: .idCards, serverDocument: liveDocument)
                            } else {
                                presentedDocument = .idCards(policy)
                            }
                        }
                    }
                )
            }
            }
        }
    }

    private func syncSelectedPolicy() {
        guard let firstPolicy = policies.first else { return }
        if !policies.contains(where: { $0.id == selectedPolicyID }) {
            selectedPolicyID = firstPolicy.id
        }
    }

    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Documents")

            ForEach(documents) { document in
                Button {
                    presentedLibraryDocument = DocumentLibraryPresentation(document: document)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: document.icon)
                            .font(.title3)
                            .foregroundStyle(Color(red: 0.03, green: 0.34, blue: 0.55))
                            .frame(width: 42, height: 42)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        Text(document.title)
                            .font(.headline)
                            .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))

                        Spacer()
                    }
                    .padding(18)
                    .background(Color(red: 0.97, green: 0.98, blue: 1.0))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func profileCard(profile: PortalProfile) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.03, green: 0.34, blue: 0.55))
                    Text(profile.initials)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                }
                .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.fullName)
                        .font(.title3.bold())
                        .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
                    Text(profile.company)
                        .foregroundStyle(Color(red: 0.33, green: 0.40, blue: 0.49))
                    Text(profile.email)
                        .font(.subheadline)
                        .foregroundStyle(Color(red: 0.33, green: 0.40, blue: 0.49))
                }
            }

            Divider()

            LabeledContent("Policyholder ID", value: profile.policyholderID)
            LabeledContent("Phone", value: profile.phone)
            LabeledContent("Garage ZIP", value: profile.zipCode)
        }
        .padding(22)
        .background(Color(red: 0.97, green: 0.98, blue: 1.0))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var accountDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Account Overview")

            DetailRow(label: "Primary Address", value: profile.address)
            DetailRow(label: "Preferred Contact", value: "Email and SMS alerts")
            DetailRow(label: "Renewal Window", value: "32 days remaining")
            DetailRow(label: "Agent", value: profile.assignedAgent)
        }
        .padding(22)
        .background(Color(red: 0.97, green: 0.98, blue: 1.0))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func sectionTitle(_ title: String, color: Color = Color(red: 0.07, green: 0.14, blue: 0.24)) -> some View {
        Text(title)
            .font(.title3.bold())
            .foregroundStyle(color)
    }
}

private enum PortalFieldStyle {
    case light
    case dark
}

private struct PortalTextField: View {
    let title: String
    @Binding var text: String
    var usesEmailKeyboard = false
    var style: PortalFieldStyle = .dark

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(style == .light ? Color.white.opacity(0.86) : Color(red: 0.33, green: 0.40, blue: 0.49))

            TextField(title, text: $text)
#if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(usesEmailKeyboard ? .emailAddress : .default)
#endif
                .padding(14)
                .background(style == .light ? Color.white.opacity(0.14) : Color.white.opacity(0.95))
                .foregroundStyle(style == .light ? .white : Color(red: 0.07, green: 0.14, blue: 0.24))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct PortalSecureField: View {
    let title: String
    @Binding var text: String
    var style: PortalFieldStyle = .dark

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(style == .light ? Color.white.opacity(0.86) : Color(red: 0.33, green: 0.40, blue: 0.49))

            SecureField(title, text: $text)
                .padding(14)
                .background(style == .light ? Color.white.opacity(0.14) : Color.white.opacity(0.95))
                .foregroundStyle(style == .light ? .white : Color(red: 0.07, green: 0.14, blue: 0.24))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct PolicyCard: View {
    let policy: PolicySummary
    let isSelected: Bool
    let onSelect: () -> Void
    let onRequestCOI: () -> Void
    let onViewCOI: () -> Void
    let onViewIDCards: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(policy.name)
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))

                Spacer()

                Text(policy.status)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.15))
                    .foregroundStyle(Color.green)
                    .clipShape(Capsule())
            }

            HStack {
                Label(policy.policyNumber, systemImage: "number.square.fill")
                Spacer()
            }
            .font(.footnote)
            .foregroundStyle(Color(red: 0.33, green: 0.40, blue: 0.49))

            HStack(spacing: 10) {
                PolicyActionChip(title: "Request COI", icon: "paperplane.fill", action: onRequestCOI)
                PolicyActionChip(title: "View COI", icon: "doc.text.fill", action: onViewCOI)
                PolicyActionChip(title: "ID Cards", icon: "wallet.pass.fill", action: onViewIDCards)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color(red: 0.83, green: 0.92, blue: 1.0) : Color(red: 0.97, green: 0.98, blue: 1.0))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(isSelected ? Color(red: 0.03, green: 0.34, blue: 0.55) : Color.clear, lineWidth: 1.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture(perform: onSelect)
    }
}

private struct PolicyActionChip: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(red: 0.03, green: 0.34, blue: 0.55))

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.92))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct StatPill: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color(red: 0.03, green: 0.34, blue: 0.55))
            Text(value)
                .font(.headline.bold())
                .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
            Text(title)
                .font(.caption)
                .foregroundStyle(Color(red: 0.33, green: 0.40, blue: 0.49))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct WideStatBar: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color(red: 0.03, green: 0.34, blue: 0.55))
                .frame(width: 42, height: 42)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.33, green: 0.40, blue: 0.49))

            Spacer()

            Text(value)
                .font(.title3.bold())
                .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct EmptyPoliciesCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No Active Policies")
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))

            Text("This client portal is active, but no bound policies are attached to the account yet.")
                .font(.subheadline)
                .foregroundStyle(Color(red: 0.33, green: 0.40, blue: 0.49))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.97, green: 0.98, blue: 1.0))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(Color(red: 0.33, green: 0.40, blue: 0.49))
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
        }
        .font(.subheadline)
    }
}

private enum PolicyDocumentKind {
    case coi
    case idCards

    var title: String {
        switch self {
        case .coi:
            return "ACORD Certificate"
        case .idCards:
            return "ID Cards"
        }
    }
}

private struct PolicyDocumentPresentation: Identifiable {
    let kind: PolicyDocumentKind
    let policy: PolicySummary
    let serverDocument: PortalServerDocument?

    var id: String {
        "\(kind.title)-\(policy.policyNumber)"
    }

    static func coi(_ policy: PolicySummary) -> PolicyDocumentPresentation {
        PolicyDocumentPresentation(kind: .coi, policy: policy, serverDocument: nil)
    }

    static func idCards(_ policy: PolicySummary) -> PolicyDocumentPresentation {
        PolicyDocumentPresentation(kind: .idCards, policy: policy, serverDocument: nil)
    }

    static func live(_ policy: PolicySummary, kind: PolicyDocumentKind, serverDocument: PortalServerDocument) -> PolicyDocumentPresentation {
        PolicyDocumentPresentation(kind: kind, policy: policy, serverDocument: serverDocument)
    }
}

private struct DocumentLibraryPresentation: Identifiable {
    let document: PortalDocument

    var id: String {
        document.title
    }
}

enum CertificateAudience: String, CaseIterable, Identifiable {
    case business = "For myself/business"
    case thirdParty = "For third party/subcontractor"

    var id: String { rawValue }
}

private struct PolicyDocumentViewer: View {
    @Environment(\.dismiss) private var dismiss

    let document: PolicyDocumentPresentation
    let session: PortalSessionStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let liveDocument = document.serverDocument,
                       let url = session.documentURL(for: liveDocument),
                       let token = session.token {
                        AuthenticatedDocumentCard(title: liveDocument.name, url: url, token: token)
                    } else {
                        EmptyDocumentCard(
                            title: document.kind == .coi ? "No COI Available" : "No ID Cards Available",
                            message: document.kind == .coi
                                ? "There is no live COI document attached to this policy in the CRM yet."
                                : "There are no ID card records stored for this policy in the CRM yet."
                        )
                    }
                }
                .padding(20)
                .frame(maxWidth: 430)
                .frame(maxWidth: .infinity)
            }
            .background(Color(red: 0.93, green: 0.96, blue: 0.99))
            .safeAreaInset(edge: .top) {
                DocumentBanner(
                    title: document.policy.name,
                    subtitle: document.policy.policyNumber,
                    onClose: { dismiss() }
                )
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct DocumentLibraryViewer: View {
    @Environment(\.dismiss) private var dismiss

    let document: DocumentLibraryPresentation
    let policies: [PolicySummary]
    let session: PortalSessionStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ForEach(Array(policies.enumerated()), id: \.element.id) { index, policy in
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(policy.name)
                                        .font(.headline.bold())
                                        .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
                                    Text(policy.policyNumber)
                                        .font(.subheadline)
                                        .foregroundStyle(Color(red: 0.33, green: 0.40, blue: 0.49))
                                }

                                Spacer()
                            }

                            let matchingDocuments = session.documents(for: policy, matching: document.document.kind)

                            if let liveDocument = matchingDocuments.first,
                               let url = session.documentURL(for: liveDocument),
                               let token = session.token {
                                AuthenticatedDocumentCard(title: liveDocument.name, url: url, token: token)
                            } else {
                                EmptyDocumentCard(
                                    title: "No \(document.document.title)",
                                    message: "There is no live \(document.document.title.lowercased()) document attached to this policy in the CRM yet."
                                )
                            }
                        }

                        if index < policies.count - 1 {
                            Divider()
                                .padding(.vertical, 4)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 430)
                .frame(maxWidth: .infinity)
            }
            .background(Color(red: 0.93, green: 0.96, blue: 0.99))
            .safeAreaInset(edge: .top) {
                DocumentBanner(
                    title: document.document.title,
                    subtitle: "All Active Policies",
                    onClose: { dismiss() }
                )
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct PolicyDeclarationsDocument: View {
    let policy: PolicySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("POLICY DECLARATIONS")
                    .font(.headline.bold())
                    .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
                Spacer()
                DocumentDownloadButton()
            }

            IDCardRow(label: "Named Insured", value: "Northline Freight LLC")
            IDCardRow(label: "Policy Number", value: policy.policyNumber)
            IDCardRow(label: "Policy Type", value: policy.name)
            IDCardRow(label: "Policy Term", value: policy.effectiveWindow)
            IDCardRow(label: "Status", value: policy.status)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct BillingScheduleDocument: View {
    let policy: PolicySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("BILLING SCHEDULE")
                    .font(.headline.bold())
                    .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
                Spacer()
                DocumentDownloadButton()
            }

            IDCardRow(label: "Policy Number", value: policy.policyNumber)
            IDCardRow(label: "Current Installment", value: "$428.00")
            IDCardRow(label: "Next Due Date", value: "05/01/2026")
            IDCardRow(label: "Payment Method", value: "Auto-pay ending in 1942")
            IDCardRow(label: "Installments Remaining", value: "6")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct DocumentBanner: View {
    let title: String
    let subtitle: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.78))
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.14))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(red: 0.05, green: 0.19, blue: 0.35))
    }
}

private struct MockAcordDocument: View {
    let policy: PolicySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("ACORD")
                    .font(.title2.bold())
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    DocumentDownloadButton()
                    Text("CERTIFICATE OF LIABILITY INSURANCE")
                        .font(.caption.bold())
                        .multilineTextAlignment(.trailing)
                }
            }

            documentRow(leftTitle: "PRODUCER", leftValue: "Vanguard Insurance Group", rightTitle: "DATE", rightValue: "04/10/2026")
            documentRow(leftTitle: "INSURED", leftValue: "Northline Freight LLC", rightTitle: "POLICY NO", rightValue: policy.policyNumber)
            documentRow(leftTitle: "LINE OF BUSINESS", leftValue: policy.name, rightTitle: "STATUS", rightValue: policy.status)

            VStack(alignment: .leading, spacing: 10) {
                Text("COVERAGES")
                    .font(.headline)
                DocumentCoverageLine(label: "Commercial General Liability", value: "Included")
                DocumentCoverageLine(label: "Automobile Liability", value: "$1,000,000")
                DocumentCoverageLine(label: "Cargo", value: "$250,000")
                DocumentCoverageLine(label: "Policy Period", value: policy.effectiveWindow)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("DESCRIPTION OF OPERATIONS")
                    .font(.headline)
                Text("Certificate issued for active policyholder verification and business operations.")
                    .font(.subheadline)
                    .foregroundStyle(Color(red: 0.22, green: 0.28, blue: 0.35))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func documentRow(leftTitle: String, leftValue: String, rightTitle: String, rightValue: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(leftTitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(leftValue)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(red: 0.08, green: 0.14, blue: 0.22))
            }

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Text(rightTitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(rightValue)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(red: 0.08, green: 0.14, blue: 0.22))
            }
        }
        .padding(.bottom, 4)
    }
}

private struct MockIDCardsDocument: View {
    let policy: PolicySummary

    var body: some View {
        VStack(spacing: 16) {
            ForEach(0..<2, id: \.self) { index in
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("INSURANCE IDENTIFICATION CARD")
                            .font(.headline.bold())
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            DocumentDownloadButton()
                            Text(index == 0 ? "Vehicle 1" : "Vehicle 2")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    IDCardRow(label: "Carrier", value: "Vanguard Insurance Group")
                    IDCardRow(label: "Policy Number", value: policy.policyNumber)
                    IDCardRow(label: "Insured", value: "Northline Freight LLC")
                    IDCardRow(label: "Policy Type", value: policy.name)
                    IDCardRow(label: "Policy Period", value: policy.effectiveWindow)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }
}

private struct DocumentDownloadButton: View {
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(Color(red: 0.03, green: 0.34, blue: 0.55))
        }
        .buttonStyle(.plain)
    }
}

private struct AuthenticatedDocumentCard: View {
    let title: String
    let url: URL
    let token: String
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline.bold())
                    .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
                Spacer()
                DocumentDownloadButton()
            }

            ZStack {
                PortalDocumentWebView(
                    url: url,
                    token: token,
                    isLoading: $isLoading
                )
                .frame(minHeight: 520)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(Color(red: 0.03, green: 0.34, blue: 0.55))
                        Text("Loading document...")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.88))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
        .padding(20)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct EmptyDocumentCard: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color(red: 0.33, green: 0.40, blue: 0.49))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

#if os(iOS)
private struct PortalDocumentWebView: UIViewRepresentable {
    let url: URL
    let token: String
    @Binding var isLoading: Bool

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if webView.url != url {
            isLoading = true
            webView.load(request)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading)
    }
}
#else
private struct PortalDocumentWebView: NSViewRepresentable {
    let url: URL
    let token: String
    @Binding var isLoading: Bool

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if webView.url != url {
            isLoading = true
            webView.load(request)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading)
    }
}
#endif

private final class Coordinator: NSObject, WKNavigationDelegate {
    @Binding var isLoading: Bool

    init(isLoading: Binding<Bool>) {
        self._isLoading = isLoading
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }
}

private struct IDCardRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color(red: 0.08, green: 0.14, blue: 0.22))
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct DocumentCoverageLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color(red: 0.22, green: 0.28, blue: 0.35))
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.08, green: 0.14, blue: 0.22))
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct CertificateRequestSheet: View {
    @Environment(\.dismiss) private var dismiss

    let policy: PolicySummary
    let session: PortalSessionStore

    @State private var audience: CertificateAudience = .business
    @State private var recipients = [RecipientInput()]
    @State private var certificateHolderName = ""
    @State private var streetAddress = ""
    @State private var cityStateZIP = ""
    @State private var isShowingSavedHolders = false
    @State private var localError: String?
    @State private var successMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(policy.name)
                        .font(.title3.bold())
                        .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))

                    Text(policy.policyNumber)
                        .font(.subheadline)
                        .foregroundStyle(Color(red: 0.33, green: 0.40, blue: 0.49))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Certificate For")
                            .font(.headline)

                        ForEach(CertificateAudience.allCases) { option in
                            Button {
                                audience = option
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: audience == option ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(Color(red: 0.03, green: 0.34, blue: 0.55))
                                    Text(option.rawValue)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
                                    Spacer()
                                }
                                .padding(16)
                                .background(Color(red: 0.96, green: 0.98, blue: 1.0))
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if audience == .thirdParty {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                isShowingSavedHolders = true
                            } label: {
                                HStack {
                                    Image(systemName: "person.2.fill")
                                    Text("Saved Certificate Holders")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.bold))
                                }
                                .padding(16)
                                .background(Color.white)
                                .foregroundStyle(Color(red: 0.03, green: 0.34, blue: 0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            Text("Certificate Holder")
                                .font(.headline)
                                .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
                            PortalTextField(title: "Certificate Holder Name", text: $certificateHolderName)
                            PortalTextField(title: "Street Address", text: $streetAddress)
                            PortalTextField(title: "City, State, ZIP", text: $cityStateZIP)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Email Recipients")
                                .font(.headline)
                            Spacer()
                            Button {
                                recipients.append(RecipientInput())
                            } label: {
                                Label("Add Recipient", systemImage: "plus")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color(red: 0.03, green: 0.34, blue: 0.55))
                        }

                        VStack(spacing: 12) {
                            ForEach($recipients) { $recipient in
                                HStack(spacing: 12) {
                                    TextField("Email", text: $recipient.email)
#if os(iOS)
                                        .textInputAutocapitalization(.never)
                                        .keyboardType(.emailAddress)
                                        .autocorrectionDisabled()
#endif
                                        .padding(14)
                                        .background(Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                                    Button {
                                        removeRecipient(recipient.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(recipients.count == 1 ? Color.gray.opacity(0.4) : Color.red)
                                            .frame(width: 42, height: 42)
                                            .background(Color.white)
                                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(recipients.count == 1)
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(red: 0.96, green: 0.98, blue: 1.0))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    if let message = localError ?? session.errorMessage {
                        Text(message)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: 12) {
                        Button("Send Certificate") {
                            submitCertificate()
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color(red: 0.03, green: 0.34, blue: 0.55))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .disabled(session.isSubmittingCOI)

                        Button("Cancel") {
                            dismiss()
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.white)
                        .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(20)
                .frame(maxWidth: 430)
                .frame(maxWidth: .infinity)
            }
            .background(Color(red: 0.92, green: 0.96, blue: 0.99))
            .navigationTitle("Request COI")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("Certificate Sent", isPresented: successBinding) {
            Button("OK") {
                dismiss()
            }
        } message: {
            Text(successMessage ?? "Certificate sent successfully.")
        }
        .sheet(isPresented: $isShowingSavedHolders) {
            SavedCertificateHoldersSheet(
                globalHolders: session.globalCertificateHolders,
                savedHolders: session.savedCertificateHolders
            ) { holder in
                certificateHolderName = holder.name
                streetAddress = holder.streetAddress
                cityStateZIP = holder.cityStateZIP
                if recipients.first?.email.isEmpty ?? true {
                    recipients[0].email = holder.email
                }
            }
        }
    }

    private func removeRecipient(_ id: UUID) {
        guard recipients.count > 1 else { return }
        recipients.removeAll { $0.id == id }
    }

    private func submitCertificate() {
        localError = nil
        session.errorMessage = nil

        let trimmedEmails = recipients
            .map { $0.email.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if trimmedEmails.isEmpty {
            localError = "Add at least one recipient email."
            return
        }

        Task {
            let holder = makeCertificateHolderPayload()
            if await session.submitCOIRequest(
                policy: policy,
                audience: audience,
                recipientEmails: trimmedEmails,
                certificateHolder: holder
            ) {
                successMessage = session.successMessage ?? "Certificate sent successfully."
            }
        }
    }

    private func makeCertificateHolderPayload() -> PortalCOICertificateHolderPayload? {
        guard audience == .thirdParty else { return nil }
        guard !certificateHolderName.isEmpty, !streetAddress.isEmpty, !cityStateZIP.isEmpty else { return nil }

        let components = cityStateZIP.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let city = components.first ?? ""
        let stateZip = components.count > 1 ? components[1].split(separator: " ").map(String.init) : []
        let state = stateZip.first ?? ""
        let zip = stateZip.dropFirst().joined(separator: " ")

        return PortalCOICertificateHolderPayload(
            name: certificateHolderName,
            company: "",
            address: streetAddress,
            city: city,
            state: state,
            zip: zip
        )
    }

    private var successBinding: Binding<Bool> {
        Binding(
            get: { successMessage != nil },
            set: { newValue in
                if !newValue {
                    successMessage = nil
                }
            }
        )
    }
}

private struct RecipientInput: Identifiable {
    let id = UUID()
    var email = ""
}

private struct SavedCertificateHoldersSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var globalSearch = ""
    @State private var savedSearch = ""

    let globalHolders: [CertificateHolder]
    let savedHolders: [CertificateHolder]
    let onSelect: (CertificateHolder) -> Void

    private var filteredGlobal: [CertificateHolder] {
        globalHolders.filter {
            globalSearch.isEmpty || $0.matches(globalSearch)
        }
    }

    private var filteredSaved: [CertificateHolder] {
        savedHolders.filter {
            savedSearch.isEmpty || $0.matches(savedSearch)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                CertificateHolderListSection(
                    title: "Global Certificate Holders",
                    searchText: $globalSearch,
                    holders: filteredGlobal,
                    onSelect: handleSelect
                )

                CertificateHolderListSection(
                    title: "Saved Certificate Holders",
                    searchText: $savedSearch,
                    holders: filteredSaved,
                    onSelect: handleSelect
                )
            }
            .padding(20)
            .background(Color(red: 0.92, green: 0.96, blue: 0.99))
            .navigationTitle("Certificate Holders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func handleSelect(_ holder: CertificateHolder) {
        onSelect(holder)
        dismiss()
    }
}

private struct CertificateHolderListSection: View {
    let title: String
    @Binding var searchText: String
    let holders: [CertificateHolder]
    let onSelect: (CertificateHolder) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))

                Spacer()

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchText)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(width: 170)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(holders) { holder in
                        Button {
                            onSelect(holder)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(holder.name)
                                    .font(.headline)
                                    .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
                                Text(holder.streetAddress)
                                    .font(.subheadline)
                                    .foregroundStyle(Color(red: 0.33, green: 0.40, blue: 0.49))
                                Text(holder.cityStateZIP)
                                    .font(.subheadline)
                                    .foregroundStyle(Color(red: 0.33, green: 0.40, blue: 0.49))
                                Text(holder.email)
                                    .font(.footnote)
                                    .foregroundStyle(Color(red: 0.03, green: 0.34, blue: 0.55))
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 210)
        }
    }
}

struct CertificateHolder: Identifiable {
    let id: String
    let name: String
    let streetAddress: String
    let cityStateZIP: String
    let email: String
    let isGlobal: Bool

    func matches(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return name.lowercased().contains(normalized)
            || streetAddress.lowercased().contains(normalized)
            || cityStateZIP.lowercased().contains(normalized)
            || email.lowercased().contains(normalized)
    }
}

private struct PortalLogoView: View {
    let url: URL?
    let height: CGFloat
    let alignment: Alignment

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Text("Vanguard Insurance Group")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Color(red: 0.07, green: 0.14, blue: 0.24))
                    }
                }
            } else {
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .frame(height: height)
        .clipped()
    }
}

private struct LogoBannerView: View {
    let url: URL?
    let height: CGFloat

    var body: some View {
        PortalLogoView(url: url, height: height, alignment: .center)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct PortalProfile {
    let firstName: String
    let fullName: String
    let company: String
    let email: String
    let phone: String
    let address: String
    let zipCode: String
    let policyholderID: String
    let assignedAgent: String

    var initials: String {
        let parts = fullName.split(separator: " ")
        return parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
    }
}

struct PolicySummary: Identifiable {
    let id = UUID()
    let policyId: String
    let name: String
    let policyNumber: String
    let coverageSummary: String
    let effectiveWindow: String
    let premium: String
    let status: String
}

struct PortalDocument: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let icon: String
    let kind: PortalDocumentKind
}

enum PortalDocumentKind {
    case idCards
    case policyDeclarations
    case billing
}

private struct ActivityItem: Identifiable {
    let id = UUID()
    let title: String
    let timestamp: String
}

private struct CertificateRequest: Identifiable {
    let id = UUID()
    let holderName: String
    let status: String
    let submittedAt: String
}

private struct CertificateRequestForm {
    var holderName = ""
    var holderAddress = ""
    var recipientEmail = ""
    var includeAdditionalInsured = false
}

private enum SamplePortalData {
    static let profile = PortalProfile(
        firstName: "Grant",
        fullName: "Grant Carter",
        company: "Northline Freight LLC",
        email: "driver@fleetsure.co",
        phone: "(216) 555-0188",
        address: "2888 Nationwide Pkwy, Brunswick, OH 44212",
        zipCode: "44212",
        policyholderID: "PH-20481",
        assignedAgent: "Grant"
    )

    static let policies = [
        PolicySummary(
            policyId: "sample-commercial-auto",
            name: "Commercial Auto",
            policyNumber: "CA-448210",
            coverageSummary: "$1M liability • physical damage • UM/UIM",
            effectiveWindow: "Apr 1, 2026 - Apr 1, 2027",
            premium: "$842/mo",
            status: "Active"
        ),
        PolicySummary(
            policyId: "sample-cargo",
            name: "Cargo Coverage",
            policyNumber: "MC-901144",
            coverageSummary: "$250K cargo • reefer breakdown • earned freight",
            effectiveWindow: "Apr 1, 2026 - Apr 1, 2027",
            premium: "$286/mo",
            status: "Active"
        ),
        PolicySummary(
            policyId: "sample-general-liability",
            name: "General Liability",
            policyNumber: "GL-551982",
            coverageSummary: "$2M aggregate • leased premises • products/completed ops",
            effectiveWindow: "Apr 1, 2026 - Apr 1, 2027",
            premium: "$156/mo",
            status: "Active"
        )
    ]

    static let documents = [
        PortalDocument(title: "ID Cards", detail: "Updated Mar 25, 2026", icon: "car.side.fill", kind: .idCards),
        PortalDocument(title: "Policy Declarations", detail: "Renewal packet for all active lines", icon: "doc.richtext.fill", kind: .policyDeclarations),
        PortalDocument(title: "Billing Schedule", detail: "6 installments remaining", icon: "calendar.badge.clock", kind: .billing)
    ]

    static let globalCertificateHolders = [
        CertificateHolder(
            id: "global-dot",
            name: "U.S. Department of Transportation",
            streetAddress: "1200 New Jersey Ave SE",
            cityStateZIP: "Washington, DC 20590",
            email: "compliance@dot.gov",
            isGlobal: true
        ),
        CertificateHolder(
            id: "global-fmcsa",
            name: "Federal Motor Carrier Safety Administration",
            streetAddress: "1200 New Jersey Ave SE",
            cityStateZIP: "Washington, DC 20590",
            email: "insurance@fmcsa.dot.gov",
            isGlobal: true
        )
    ]

    static let savedCertificateHolders = [
        CertificateHolder(
            id: "saved-blue-ridge",
            name: "Blue Ridge Logistics",
            streetAddress: "4510 Harbor Commerce Rd",
            cityStateZIP: "Cleveland, OH 44114",
            email: "dispatch@blueridgelogistics.com",
            isGlobal: false
        ),
        CertificateHolder(
            id: "saved-sterling",
            name: "Sterling Freight Brokers",
            streetAddress: "88 West Junction Ave",
            cityStateZIP: "Columbus, OH 43215",
            email: "ops@sterlingfreight.com",
            isGlobal: false
        ),
        CertificateHolder(
            id: "saved-atlas",
            name: "Atlas Jobsite Services",
            streetAddress: "203 Industrial Park Dr",
            cityStateZIP: "Toledo, OH 43604",
            email: "risk@atlasjobsite.com",
            isGlobal: false
        )
    ]

    static let activity = [
        ActivityItem(title: "Certificate issued for Blue Ridge Logistics", timestamp: "Today at 9:14 AM"),
        ActivityItem(title: "Autopay processed for commercial auto policy", timestamp: "Apr 4, 2026"),
        ActivityItem(title: "Renewal review call scheduled with advisor", timestamp: "Apr 2, 2026")
    ]

    static let requests = [
        CertificateRequest(holderName: "Blue Ridge Logistics", status: "Issued", submittedAt: "Today at 9:14 AM"),
        CertificateRequest(holderName: "Sterling Freight Brokers", status: "Pending", submittedAt: "Yesterday at 2:40 PM")
    ]
}

#Preview {
    ContentView()
}
