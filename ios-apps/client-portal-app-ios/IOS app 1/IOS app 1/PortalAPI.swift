import Foundation

enum PortalAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case auth(code: String, message: String)
    case unauthorized(String)
    case server(String)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .auth(_, let message):
            return message
        case .unauthorized(let message), .server(let message):
            return message
        case .decodingFailed:
            return "The app could not read the server response."
        }
    }
}

struct PortalAuthResponse: Decodable {
    let token: String
    let expiresIn: String
    let clientId: String
    let name: String
}

struct PortalAuthErrorResponse: Decodable {
    let code: String?
    let error: String
}

struct PortalSetupPasswordPayload: Encodable {
    let email: String
    let newPassword: String
}

struct PortalRequestPasswordResetPayload: Encodable {
    let email: String
}

struct PortalRequestPasswordResetResponse: Decodable {
    let resetToken: String?
    let message: String?
}

struct PortalCompletePasswordResetPayload: Encodable {
    let resetToken: String
    let newPassword: String
}

struct PortalProfileResponse: Decodable {
    let accountId: String
    let name: String
    let fullName: String
    let businessName: String
    let email: String
    let phone: String
    let address: String
    let city: String
    let state: String
    let zip: String
    let type: String
    let status: String
    let assignedAgent: String
}

struct PortalPoliciesResponse: Decodable {
    let policies: [PortalPolicyResponse]
    let count: Int
}

struct PortalPolicyResponse: Decodable {
    let policyId: String
    let policyNumber: String
    let policyType: String
    let policyName: String
    let carrier: String
    let status: String
    let effectiveDate: String
    let expirationDate: String
    let premium: String
    let insuredName: String
    let dotNumber: String
    let mcNumber: String
    let agent: String
}

struct PortalPolicyDocumentsResponse: Decodable {
    let documents: [PortalServerDocument]
}

struct PortalServerDocument: Decodable, Identifiable {
    let id: String
    let docType: String
    let name: String
    let mimeType: String
    let uploadDate: String
    let downloadUrl: String
    let source: String

    var normalizedType: String {
        docType.lowercased()
    }
}

struct PortalCertificateHoldersResponse: Decodable {
    let certificateHolders: [PortalCertificateHolderResponse]
}

struct PortalCertificateHolderResponse: Decodable {
    let id: String
    let name: String
    let company: String
    let address: String
    let city: String
    let state: String
    let zip: String
    let isGlobal: Bool
}

struct PortalCOIRequestResponse: Decodable {
    let requestId: String
    let status: String
    let sentTo: [String]?
    let message: String
    let estimatedTime: String?
}

struct PortalCOIRequestPayload: Encodable {
    let policyId: String
    let requestType: String
    let recipientEmails: [String]
    let certificateHolder: PortalCOICertificateHolderPayload?
    let additionalNotes: String
}

struct PortalCOICertificateHolderPayload: Encodable {
    let name: String
    let company: String
    let address: String
    let city: String
    let state: String
    let zip: String
}

actor PortalAPIClient {
    static let shared = PortalAPIClient()

    private let baseURL = URL(string: "https://162-220-14-239.nip.io/api/portal")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func login(email: String, password: String) async throws -> PortalAuthResponse {
        let body = ["email": email, "password": password]
        return try await request(path: "login", method: "POST", body: body, token: nil)
    }

    func setupPassword(email: String, newPassword: String) async throws -> PortalAuthResponse {
        let body = PortalSetupPasswordPayload(email: email, newPassword: newPassword)
        return try await request(path: "setup-password", method: "POST", body: body, token: nil)
    }

    func requestPasswordReset(email: String) async throws -> PortalRequestPasswordResetResponse {
        let body = PortalRequestPasswordResetPayload(email: email)
        return try await request(path: "request-password-reset", method: "POST", body: body, token: nil)
    }

    func completePasswordReset(resetToken: String, newPassword: String) async throws -> PortalAuthResponse {
        let body = PortalCompletePasswordResetPayload(resetToken: resetToken, newPassword: newPassword)
        return try await request(path: "complete-password-reset", method: "POST", body: body, token: nil)
    }

    func fetchProfile(token: String) async throws -> PortalProfileResponse {
        try await request(path: "me", method: "GET", token: token)
    }

    func fetchPolicies(token: String) async throws -> PortalPoliciesResponse {
        try await request(path: "policies", method: "GET", token: token)
    }

    func fetchDocuments(policyId: String, token: String) async throws -> [PortalServerDocument] {
        let response: PortalPolicyDocumentsResponse = try await request(path: "policies/\(policyId)/documents", method: "GET", token: token)
        return response.documents
    }

    func fetchCertificateHolders(token: String) async throws -> [PortalCertificateHolderResponse] {
        let response: PortalCertificateHoldersResponse = try await request(path: "certificate-holders", method: "GET", token: token)
        return response.certificateHolders
    }

    func submitCOIRequest(payload: PortalCOIRequestPayload, token: String) async throws -> PortalCOIRequestResponse {
        try await request(path: "coi/request", method: "POST", body: payload, token: token)
    }

    nonisolated func makeDocumentURL(path: String) -> URL? {
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }

        guard
            let scheme = baseURL.scheme,
            let host = baseURL.host
        else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = baseURL.port
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        return components.url
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        token: String? = nil
    ) async throws -> T {
        try await request(path: path, method: method, body: Optional<String>.none, token: token)
    }

    private func request<T: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        token: String?
    ) async throws -> T {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PortalAPIError.invalidResponse
        }

        if (200..<300).contains(http.statusCode) {
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw PortalAPIError.decodingFailed
            }
        }

        if let apiError = try? JSONDecoder().decode(PortalAuthErrorResponse.self, from: data) {
            if let code = apiError.code {
                throw PortalAPIError.auth(code: code, message: apiError.error)
            }
            if http.statusCode == 401 {
                throw PortalAPIError.unauthorized(apiError.error)
            }
            throw PortalAPIError.server(apiError.error)
        }

        throw PortalAPIError.server("Server error \(http.statusCode)")
    }
}
