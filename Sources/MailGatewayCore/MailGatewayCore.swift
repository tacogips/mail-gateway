import Foundation

public enum MailGatewayExitCode: Int32, Sendable {
    case success = 0
    case generalError = 1
    case invalidCliUsage = 2
    case configurationError = 3
    case authenticationBootstrapError = 4
    case graphqlExecutionError = 5
    case providerApiError = 6
}

public enum MailGatewayErrorCode: String, Sendable {
    case accountNotFound = "ACCOUNT_NOT_FOUND"
    case attachmentNotFound = "ATTACHMENT_NOT_FOUND"
    case authBootstrapNotImplemented = "AUTH_BOOTSTRAP_NOT_IMPLEMENTED"
    case authRequired = "AUTH_REQUIRED"
    case configInvalid = "CONFIG_INVALID"
    case credentialNotFound = "CREDENTIAL_NOT_FOUND"
    case invalidArgument = "INVALID_ARGUMENT"
    case messageNotFound = "MESSAGE_NOT_FOUND"
    case providerRateLimited = "PROVIDER_RATE_LIMITED"
    case sendDisabledInReader = "SEND_DISABLED_IN_READER"
    case sendNotSupported = "SEND_NOT_SUPPORTED"
}

public struct MailGatewayCommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public struct MailGatewayError: Error, Sendable {
    public let message: String
    public let code: MailGatewayErrorCode
    public let exitCode: MailGatewayExitCode
    public let details: [String: String]

    public init(
        _ message: String,
        code: MailGatewayErrorCode,
        exitCode: MailGatewayExitCode,
        details: [String: String] = [:]
    ) {
        self.message = message
        self.code = code
        self.exitCode = exitCode
        self.details = details
    }
}

public enum MailProvider: String, Codable, Equatable, Sendable {
    case gmail

    var graphQLValue: String {
        switch self {
        case .gmail:
            return "GMAIL"
        }
    }
}

public enum AccessMode: String, Codable, Equatable, Sendable {
    case read
    case readSend = "read_send"

    var graphQLValue: String {
        switch self {
        case .read:
            return "READ"
        case .readSend:
            return "READ_SEND"
        }
    }
}

public enum AuthState: String, Codable, Equatable, Sendable {
    case missing = "MISSING"
    case ready = "READY"
    case expired = "EXPIRED"
    case scopeMismatch = "SCOPE_MISMATCH"
    case invalid = "INVALID"
    case unknown = "UNKNOWN"
}

public enum AttachmentMaterializationState: String, Codable, Equatable, Sendable {
    case notMaterialized = "NOT_MATERIALIZED"
    case cached = "CACHED"
    case materialized = "MATERIALIZED"
}

public enum MessageMaterializedFileKind: String, Codable, Equatable, Sendable {
    case bodyText = "BODY_TEXT"
    case bodyHTML = "BODY_HTML"
    case temporaryFile = "TEMPORARY_FILE"
}

public struct StorageConfig: Sendable {
    public let cacheDir: String
    public let attachmentDir: String
    public let allowedSendAttachmentRoots: [String]
}

public struct CredentialConfig: Sendable {
    public let id: String
    public let provider: MailProvider
    public let accessMode: AccessMode
    public let oauthClientSecretPath: String
    public let tokenStorePath: String
}

public struct AccountConfig: Sendable {
    public let id: String
    public let provider: MailProvider
    public let emailAddress: String
    public let credentialId: String
    public let defaultLabelIds: [String]
}

public struct MailGatewayConfig: Sendable {
    public let configPath: String
    public let storage: StorageConfig
    public let credentials: [CredentialConfig]
    public let accounts: [AccountConfig]
}

public struct MailGatewayReaderService {
    let config: MailGatewayConfig
    let cacheRoot: String
    let attachmentRoot: String
    private let allowedSendAttachmentRoots: [String]

    public init(config: MailGatewayConfig) {
        self.config = config
        self.cacheRoot = normalizedPath(config.storage.cacheDir)
        self.attachmentRoot = normalizedPath(config.storage.attachmentDir)
        self.allowedSendAttachmentRoots = config.storage.allowedSendAttachmentRoots.map(normalizedPath)
    }

    public func listAccounts() -> [[String: Any]] {
        config.accounts
            .sorted { $0.id < $1.id }
            .map { buildMailAccount($0, graphQL: false) }
    }

    public func graphQLAccounts() -> [[String: Any]] {
        config.accounts
            .sorted { $0.id < $1.id }
            .map { buildMailAccount($0, graphQL: true) }
    }

    public func graphQLAccount(id: String) -> [String: Any]? {
        guard let account = config.accounts.first(where: { $0.id == id }) else {
            return nil
        }
        return buildMailAccount(account, graphQL: true)
    }

    public func searchThreads(accountId: String) throws -> [String: Any] {
        _ = try requireAccount(accountId)
        let pageInfo: [String: Any] = [
            "hasNextPage": false,
            "endCursor": NSNull()
        ]
        return [
            "edges": [[String: Any]](),
            "pageInfo": pageInfo,
            "totalCount": 0
        ]
    }

    public func getThread(accountId: String, threadId _: String) throws -> Any {
        _ = try requireAccount(accountId)
        return NSNull()
    }

    public func getMessage(accountId: String, messageId _: String) throws -> Any {
        _ = try requireAccount(accountId)
        return NSNull()
    }

    public func getAttachment(accountId: String, messageId: String, attachmentId: String) throws -> Any {
        _ = try requireAccount(accountId)
        let attachmentDirectory = URL(fileURLWithPath: attachmentRoot)
            .appendingPathComponent(accountId, isDirectory: true)
            .appendingPathComponent(messageId, isDirectory: true)
            .path
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: attachmentDirectory)) ?? []
        guard let matchingEntry = entries.first(where: { $0.hasPrefix("\(attachmentId)-") }) else {
            return NSNull()
        }
        let localPath = normalizedPath(URL(fileURLWithPath: attachmentDirectory)
            .appendingPathComponent(matchingEntry)
            .path)
        let filename = String(matchingEntry.dropFirst("\(attachmentId)-".count))
        return [
            "id": attachmentId,
            "filename": filename.isEmpty ? NSNull() : filename as Any,
            "mimeType": "application/octet-stream",
            "sizeBytes": NSNull(),
            "localPath": localPath,
            "materializationState": AttachmentMaterializationState.cached.rawValue
        ]
    }

    public func getAuthStatus(credentialId: String) throws -> [String: Any] {
        let credential = try requireCredential(credentialId)
        let tokenState = inspectTokenStore(credential: credential)
        return [
            "credentialId": credential.id,
            "provider": credential.provider.rawValue,
            "configuredAccessMode": credential.accessMode.rawValue,
            "state": tokenState.state.rawValue,
            "tokenStorePath": credential.tokenStorePath,
            "tokenStoreExists": tokenState.exists,
            "grantedAccessMode": tokenState.grantedAccessMode?.rawValue as Any? ?? NSNull(),
            "expiresAt": tokenState.expiresAt as Any? ?? NSNull(),
            "hasRefreshToken": tokenState.hasRefreshToken
        ]
    }

    public func revokeAuth(credentialId: String) throws -> [String: Any] {
        let credential = try requireCredential(credentialId)
        let existed = FileManager.default.fileExists(atPath: credential.tokenStorePath)
        if existed {
            do {
                try FileManager.default.removeItem(atPath: credential.tokenStorePath)
            } catch {
                throw MailGatewayError(
                    "Failed to revoke token store for credential \(credential.id)",
                    code: .authRequired,
                    exitCode: .authenticationBootstrapError,
                    details: ["cause": error.localizedDescription]
                )
            }
        }
        return ["credentialId": credentialId, "revoked": existed]
    }

    public func login(credentialId: String) throws -> Never {
        let credential = try requireCredential(credentialId)
        throw MailGatewayError(
            "Interactive auth bootstrap is not implemented for provider \(credential.provider.rawValue)",
            code: .authBootstrapNotImplemented,
            exitCode: .authenticationBootstrapError,
            details: ["credentialId": credential.id]
        )
    }

    public func pruneCache(accountId: String?, all: Bool) throws -> [String: Any] {
        if !all && accountId == nil {
            throw MailGatewayError(
                "cache prune requires --all or --account",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }
        if all && accountId != nil {
            throw MailGatewayError(
                "cache prune accepts either --all or --account, but not both",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }

        try FileManager.default.createDirectory(
            atPath: attachmentRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let targets: [String]
        if all || accountId == nil {
            targets = [attachmentRoot]
        } else {
            let account = try requireAccount(accountId!)
            targets = [URL(fileURLWithPath: attachmentRoot).appendingPathComponent(account.id, isDirectory: true).path]
        }

        var prunedPaths: [String] = []
        for target in targets {
            let normalizedTarget = try assertWithinAttachmentRoot(target)
            try? FileManager.default.removeItem(atPath: normalizedTarget)
            if all {
                try FileManager.default.createDirectory(
                    atPath: attachmentRoot,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            prunedPaths.append(normalizedTarget)
        }
        return ["prunedPaths": prunedPaths]
    }

    public func validateSendAttachmentPath(_ candidatePath: String) throws -> String {
        let normalizedCandidate = normalizedPath(candidatePath)
        let isAllowed = allowedSendAttachmentRoots.contains {
            isWithinRoot(rootPath: $0, candidatePath: normalizedCandidate)
        }
        if !isAllowed {
            throw MailGatewayError(
                "Attachment path is outside allowed_send_attachment_roots",
                code: .configInvalid,
                exitCode: .configurationError,
                details: ["candidatePath": normalizedCandidate]
            )
        }
        return normalizedCandidate
    }

    private func buildMailAccount(_ account: AccountConfig, graphQL: Bool) -> [String: Any] {
        let credential = try? requireCredential(account.credentialId)
        let tokenState = credential.map(inspectTokenStore)?.state ?? .missing
        let configuredAccessMode = graphQL
            ? credential?.accessMode.graphQLValue ?? AccessMode.read.graphQLValue
            : credential?.accessMode.rawValue ?? AccessMode.read.rawValue
        let capabilities: [String: Any] = [
            "canRead": true,
            "canSend": false,
            "configuredAccessMode": configuredAccessMode,
            "authState": tokenState.rawValue
        ]
        return [
            "id": account.id,
            "provider": graphQL ? account.provider.graphQLValue : account.provider.rawValue,
            "emailAddress": account.emailAddress,
            "capabilities": capabilities
        ]
    }

    private func requireCredential(_ credentialId: String) throws -> CredentialConfig {
        guard let credential = config.credentials.first(where: { $0.id == credentialId }) else {
            throw MailGatewayError(
                "Unknown credential: \(credentialId)",
                code: .credentialNotFound,
                exitCode: .configurationError
            )
        }
        return credential
    }

    func requireAccount(_ accountId: String) throws -> AccountConfig {
        guard let account = config.accounts.first(where: { $0.id == accountId }) else {
            throw MailGatewayError(
                "Unknown account: \(accountId)",
                code: .accountNotFound,
                exitCode: .graphqlExecutionError
            )
        }
        return account
    }

    private func assertWithinAttachmentRoot(_ target: String) throws -> String {
        let normalizedTarget = normalizedPath(target)
        if !isWithinRoot(rootPath: attachmentRoot, candidatePath: normalizedTarget) {
            throw MailGatewayError(
                "Refusing to prune outside the configured attachment root",
                code: .configInvalid,
                exitCode: .configurationError,
                details: ["target": normalizedTarget, "storageRoot": attachmentRoot]
            )
        }
        return normalizedTarget
    }

}
