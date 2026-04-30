import Foundation
import Observation

enum LoginFlowState: Equatable {
    case idle
    case needsPasswordSetup(email: String)
    case needsPasswordReset(email: String, resetToken: String?)
}

@MainActor
@Observable
final class PortalSessionStore {
    private let api = PortalAPIClient.shared
    private let tokenKey = "portal.auth.token"

    var token: String?
    var isBootstrapping = false
    var isLoading = false
    var isSubmittingCOI = false
    var errorMessage: String?
    var successMessage: String?
    var loginFlowState: LoginFlowState = .idle
    var profile: PortalProfile?
    var policies: [PolicySummary] = []
    var documentsByPolicyID: [String: [PortalServerDocument]] = [:]
    var globalCertificateHolders: [CertificateHolder] = []
    var savedCertificateHolders: [CertificateHolder] = []

    var isAuthenticated: Bool {
        token != nil
    }

    init() {
        token = UserDefaults.standard.string(forKey: tokenKey)
    }

    func bootstrap() async {
        guard token != nil, !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }

        do {
            try await loadPortalData()
        } catch {
            logout()
        }
    }

    func login(email: String, password: String) async -> Bool {
        isLoading = true
        errorMessage = nil
        loginFlowState = .idle
        defer { isLoading = false }

        do {
            let auth = try await api.login(email: email, password: password)
            token = auth.token
            UserDefaults.standard.set(auth.token, forKey: tokenKey)
            try await loadPortalData()
            return true
        } catch {
            handleLoginError(error, email: email)
            return false
        }
    }

    func setupPassword(email: String, newPassword: String) async -> Bool {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let auth = try await api.setupPassword(email: email, newPassword: newPassword)
            token = auth.token
            UserDefaults.standard.set(auth.token, forKey: tokenKey)
            loginFlowState = .idle
            try await loadPortalData()
            return true
        } catch {
            if case let PortalAPIError.auth(code, message) = error {
                switch code {
                case "WEAK_PASSWORD":
                    errorMessage = "Password must be at least 8 characters."
                case "PASSWORD_ALREADY_SET":
                    errorMessage = "Password already exists. Use your password to sign in."
                case "EMAIL_NOT_FOUND":
                    errorMessage = "No account found for that email."
                default:
                    errorMessage = message
                }
            } else {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    func logout() {
        token = nil
        profile = nil
        policies = []
        documentsByPolicyID = [:]
        globalCertificateHolders = []
        savedCertificateHolders = []
        errorMessage = nil
        loginFlowState = .idle
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }

    func requestPasswordReset(email: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await api.requestPasswordReset(email: email)
            loginFlowState = .needsPasswordReset(email: email, resetToken: response.resetToken)
            errorMessage = response.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completePasswordReset(email: String, resetToken: String, newPassword: String) async -> Bool {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let auth = try await api.completePasswordReset(resetToken: resetToken, newPassword: newPassword)
            token = auth.token
            UserDefaults.standard.set(auth.token, forKey: tokenKey)
            loginFlowState = .idle
            try await loadPortalData()
            return true
        } catch {
            if case let PortalAPIError.auth(code, message) = error {
                switch code {
                case "INVALID_TOKEN":
                    errorMessage = "Reset token is invalid or expired."
                case "WEAK_PASSWORD":
                    errorMessage = "Password must be at least 8 characters."
                case "EMAIL_NOT_FOUND":
                    errorMessage = "No account found for that email."
                default:
                    errorMessage = message
                }
            } else {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    func loadPortalData() async throws {
        guard let token else { return }

        isLoading = true
        defer { isLoading = false }

        async let profileResponse = api.fetchProfile(token: token)
        async let policiesResponse = api.fetchPolicies(token: token)
        async let holderResponses = api.fetchCertificateHolders(token: token)

        let resolvedProfile = try await profileResponse
        let resolvedPolicies = try await policiesResponse
        let resolvedHolders = try await holderResponses

        profile = PortalProfile(
            firstName: resolvedProfile.fullName.split(separator: " ").first.map(String.init) ?? resolvedProfile.fullName,
            fullName: resolvedProfile.fullName,
            company: resolvedProfile.businessName,
            email: resolvedProfile.email,
            phone: resolvedProfile.phone,
            address: "\(resolvedProfile.address), \(resolvedProfile.city), \(resolvedProfile.state) \(resolvedProfile.zip)",
            zipCode: resolvedProfile.zip,
            policyholderID: resolvedProfile.accountId,
            assignedAgent: resolvedProfile.assignedAgent
        )

        policies = resolvedPolicies.policies.map {
            PolicySummary(
                policyId: $0.policyId,
                name: $0.policyName,
                policyNumber: $0.policyNumber,
                coverageSummary: $0.carrier,
                effectiveWindow: "\($0.effectiveDate) - \($0.expirationDate)",
                premium: $0.premium,
                status: $0.status
            )
        }

        let holders = resolvedHolders.map {
            CertificateHolder(
                id: $0.id,
                name: $0.name.isEmpty ? $0.company : $0.name,
                streetAddress: $0.address,
                cityStateZIP: "\($0.city), \($0.state) \($0.zip)",
                email: "",
                isGlobal: $0.isGlobal
            )
        }
        globalCertificateHolders = holders.filter(\.isGlobal)
        savedCertificateHolders = holders.filter { !$0.isGlobal }

        try await loadDocumentsForPolicies()
    }

    func loadDocumentsForPolicies() async throws {
        guard let token else { return }

        var loaded: [String: [PortalServerDocument]] = [:]
        for policy in policies {
            loaded[policy.policyId] = try await api.fetchDocuments(policyId: policy.policyId, token: token)
        }
        documentsByPolicyID = loaded
    }

    func refreshDocuments(for policy: PolicySummary) async {
        guard let token else { return }

        do {
            let documents = try await api.fetchDocuments(policyId: policy.policyId, token: token)
            documentsByPolicyID[policy.policyId] = documents
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func documentURL(for document: PortalServerDocument) -> URL? {
        api.makeDocumentURL(path: document.downloadUrl)
    }

    func firstDocument(for policy: PolicySummary, matching type: String) -> PortalServerDocument? {
        documentsByPolicyID[policy.policyId]?.first { $0.normalizedType == type }
    }

    func documents(for policy: PolicySummary, matching kind: PortalDocumentKind) -> [PortalServerDocument] {
        let type: String
        switch kind {
        case .idCards:
            type = "id_card"
        case .policyDeclarations:
            type = "declaration"
        case .billing:
            type = "billing"
        }
        return documentsByPolicyID[policy.policyId]?.filter { $0.normalizedType == type } ?? []
    }

    func submitCOIRequest(
        policy: PolicySummary,
        audience: CertificateAudience,
        recipientEmails: [String],
        certificateHolder: PortalCOICertificateHolderPayload?,
        additionalNotes: String = ""
    ) async -> Bool {
        guard let token else { return false }

        isSubmittingCOI = true
        errorMessage = nil
        successMessage = nil
        defer { isSubmittingCOI = false }

        do {
            let payload = PortalCOIRequestPayload(
                policyId: policy.policyId,
                requestType: "third_party",
                recipientEmails: recipientEmails,
                certificateHolder: certificateHolder,
                additionalNotes: additionalNotes
            )

            let response = try await api.submitCOIRequest(payload: payload, token: token)
            successMessage = response.message
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func handleLoginError(_ error: Error, email: String) {
        if case let PortalAPIError.auth(code, message) = error {
            switch code {
            case "EMAIL_NOT_FOUND":
                errorMessage = "No account found for that email."
            case "PASSWORD_NOT_SET":
                errorMessage = nil
                loginFlowState = .needsPasswordSetup(email: email)
            case "WRONG_PASSWORD":
                errorMessage = "Incorrect password."
            case "MISSING_FIELDS":
                errorMessage = "Enter your email and password."
            default:
                errorMessage = message
            }
            return
        }

        errorMessage = error.localizedDescription
    }
}
