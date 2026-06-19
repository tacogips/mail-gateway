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

private struct ParsedArgs {
    let positionals: [String]
    let flags: [String: StringOrBool]
}

private enum StringOrBool {
    case string(String)
    case bool(Bool)
}

private enum TomlSection {
    case none
    case storage
    case credential(Int)
    case account(Int)
}

public enum MailGatewayConfigLoader {
    public static func getCredentialPathEnvVarName(credentialId: String, pathKey: String) -> String {
        let suffix = credentialId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "_"
            }
        let normalized = String(suffix)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            .uppercased()
        let safeSuffix = normalized.isEmpty ? "CREDENTIAL" : normalized
        if pathKey == "oauth_client_secret_path" {
            return "MAIL_GATEWAY_CREDENTIAL_\(safeSuffix)_OAUTH_CLIENT_SECRET_PATH"
        }
        return "MAIL_GATEWAY_CREDENTIAL_\(safeSuffix)_TOKEN_STORE_PATH"
    }

    public static func resolveDefaultConfigPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let xdgConfigHome = nonBlank(environment["XDG_CONFIG_HOME"]) {
            return normalizedPath(URL(fileURLWithPath: xdgConfigHome)
                .appendingPathComponent("mail-gateway")
                .appendingPathComponent("config.toml")
                .path)
        }
        return normalizedPath(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("mail-gateway")
            .appendingPathComponent("config.toml")
            .path)
    }

    public static func loadConfig(
        configPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> MailGatewayConfig {
        let selectedConfigPath = normalizedPath(configPath ?? environment["MAIL_GATEWAY_CONFIG"] ?? resolveDefaultConfigPath(environment: environment))
        let source: String
        do {
            source = try String(contentsOfFile: selectedConfigPath, encoding: .utf8)
        } catch {
            throw MailGatewayError(
                "Failed to read config: \(selectedConfigPath)",
                code: .configInvalid,
                exitCode: .configurationError,
                details: ["cause": error.localizedDescription]
            )
        }

        let parsed = try parseTomlSubset(source)
        guard let storageRecord = parsed.storage else {
            throw configError("storage must be a table/object")
        }
        if parsed.credentials.isEmpty {
            throw configError("credentials must be a non-empty array")
        }
        if parsed.accounts.isEmpty {
            throw configError("accounts must be a non-empty array")
        }

        let storage = try parseStorageConfig(storageRecord, configPath: selectedConfigPath)
        let credentials = try parsed.credentials.enumerated().map { index, record in
            try parseCredentialConfig(record, index: index, configPath: selectedConfigPath, environment: environment)
        }
        let accounts = try parsed.accounts.enumerated().map { index, record in
            try parseAccountConfig(record, index: index)
        }

        try ensureUnique(credentials.map(\.id), context: "credentials.id")
        try ensureUnique(accounts.map(\.id), context: "accounts.id")
        try ensureUnique(credentials.map(\.tokenStorePath), context: "credentials.token_store_path")
        try validateAccountCredentialLinks(credentials: credentials, accounts: accounts)

        for credential in credentials where !FileManager.default.isReadableFile(atPath: credential.oauthClientSecretPath) {
            throw configError("credentials.\(credential.id).oauth_client_secret_path is not readable: \(credential.oauthClientSecretPath)")
        }

        return MailGatewayConfig(
            configPath: selectedConfigPath,
            storage: storage,
            credentials: credentials,
            accounts: accounts
        )
    }

    public static func validateConfig(
        configPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [String: Any] {
        let config = try loadConfig(configPath: configPath, environment: environment)
        return [
            "ok": true,
            "configPath": config.configPath,
            "accountIds": config.accounts.map(\.id),
            "credentialIds": config.credentials.map(\.id)
        ]
    }
}

public struct MailGatewayReaderService {
    private let config: MailGatewayConfig
    private let attachmentRoot: String
    private let allowedSendAttachmentRoots: [String]

    public init(config: MailGatewayConfig) {
        self.config = config
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
        if !allowedSendAttachmentRoots.contains(where: { isWithinRoot(rootPath: $0, candidatePath: normalizedCandidate) }) {
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
        let capabilities: [String: Any] = [
            "canRead": true,
            "canSend": false,
            "configuredAccessMode": graphQL ? (credential?.accessMode.graphQLValue ?? AccessMode.read.graphQLValue) : (credential?.accessMode.rawValue ?? AccessMode.read.rawValue),
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

    private func requireAccount(_ accountId: String) throws -> AccountConfig {
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

public struct MailGatewayCLI {
    public init() {}

    public func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> MailGatewayCommandResult {
        do {
            let parsed = try parseArguments(arguments)
            let command = parsed.positionals.first
            let subcommand = parsed.positionals.dropFirst().first
            let configPath = try getStringFlag(parsed.flags, "config") ?? environment["MAIL_GATEWAY_CONFIG"]
            let pretty = try getBooleanFlag(parsed.flags, "pretty")

            switch command {
            case "graphql":
                let config = try MailGatewayConfigLoader.loadConfig(configPath: configPath, environment: environment)
                let query = try loadQuery(flags: parsed.flags)
                _ = try loadVariables(flags: parsed.flags)
                let result = try executeReaderGraphQL(config: config, query: query)
                return MailGatewayCommandResult(
                    exitCode: result.exitCode.rawValue,
                    stdout: jsonString(result.body, pretty: pretty) + "\n",
                    stderr: ""
                )
            case "config":
                guard subcommand == "validate" else {
                    throw MailGatewayError(
                        "config requires the validate subcommand",
                        code: .invalidArgument,
                        exitCode: .invalidCliUsage
                    )
                }
                return success(try MailGatewayConfigLoader.validateConfig(configPath: configPath, environment: environment), pretty: pretty)
            case "auth":
                let credentialId = try getStringFlag(parsed.flags, "credential")
                guard let credentialId else {
                    throw MailGatewayError(
                        "auth commands require --credential",
                        code: .invalidArgument,
                        exitCode: .invalidCliUsage
                    )
                }
                let service = MailGatewayReaderService(config: try MailGatewayConfigLoader.loadConfig(configPath: configPath, environment: environment))
                switch subcommand {
                case "status":
                    return success(try service.getAuthStatus(credentialId: credentialId), pretty: pretty)
                case "revoke":
                    return success(try service.revokeAuth(credentialId: credentialId), pretty: pretty)
                case "login":
                    try service.login(credentialId: credentialId)
                default:
                    throw MailGatewayError(
                        "auth requires one of: login, revoke, status",
                        code: .invalidArgument,
                        exitCode: .invalidCliUsage
                    )
                }
            case "cache":
                guard subcommand == "prune" else {
                    throw MailGatewayError(
                        "cache requires the prune subcommand",
                        code: .invalidArgument,
                        exitCode: .invalidCliUsage
                    )
                }
                let service = MailGatewayReaderService(config: try MailGatewayConfigLoader.loadConfig(configPath: configPath, environment: environment))
                return success(
                    try service.pruneCache(
                        accountId: try getStringFlag(parsed.flags, "account"),
                        all: try getBooleanFlag(parsed.flags, "all")
                    ),
                    pretty: pretty
                )
            default:
                throw MailGatewayError(
                    "Supported commands: graphql, config validate, auth <login|revoke|status>, cache prune",
                    code: .invalidArgument,
                    exitCode: .invalidCliUsage
                )
            }
        } catch let error as MailGatewayError {
            return MailGatewayCommandResult(
                exitCode: error.exitCode.rawValue,
                stdout: "",
                stderr: jsonString(errorOutput(error), pretty: true) + "\n"
            )
        } catch {
            let appError = MailGatewayError(
                String(describing: error),
                code: .configInvalid,
                exitCode: .generalError
            )
            return MailGatewayCommandResult(
                exitCode: appError.exitCode.rawValue,
                stdout: "",
                stderr: jsonString(errorOutput(appError), pretty: true) + "\n"
            )
        }
    }

    private func success(_ payload: [String: Any], pretty: Bool) -> MailGatewayCommandResult {
        MailGatewayCommandResult(
            exitCode: MailGatewayExitCode.success.rawValue,
            stdout: jsonString(payload, pretty: pretty) + "\n",
            stderr: ""
        )
    }
}

private struct TokenInspectionResult {
    let state: AuthState
    let exists: Bool
    let grantedAccessMode: AccessMode?
    let expiresAt: String?
    let hasRefreshToken: Bool
}

private func inspectTokenStore(credential: CredentialConfig) -> TokenInspectionResult {
    guard FileManager.default.isReadableFile(atPath: credential.tokenStorePath) else {
        return TokenInspectionResult(
            state: .missing,
            exists: false,
            grantedAccessMode: nil,
            expiresAt: nil,
            hasRefreshToken: false
        )
    }
    guard let data = FileManager.default.contents(atPath: credential.tokenStorePath),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return invalidTokenResult()
    }

    let accessMode = AccessMode(rawValue: parsed["accessMode"] as? String ?? "")
    let refreshToken = parsed["refreshToken"] as? String
    let hasRefreshToken = refreshToken?.isEmpty == false
    let expiresAt = (parsed["expiresAt"] as? String).flatMap(nonBlank)

    if let accessMode,
       accessMode != credential.accessMode {
        return TokenInspectionResult(
            state: .scopeMismatch,
            exists: true,
            grantedAccessMode: accessMode,
            expiresAt: expiresAt,
            hasRefreshToken: hasRefreshToken
        )
    }

    if let expiresAt {
        guard let expiresAtDate = parseDate(expiresAt) else {
            return TokenInspectionResult(
                state: .invalid,
                exists: true,
                grantedAccessMode: accessMode,
                expiresAt: expiresAt,
                hasRefreshToken: hasRefreshToken
            )
        }
        if expiresAtDate <= Date(),
           !hasRefreshToken {
            return TokenInspectionResult(
                state: .expired,
                exists: true,
                grantedAccessMode: accessMode,
                expiresAt: expiresAt,
                hasRefreshToken: hasRefreshToken
            )
        }
    }

    return TokenInspectionResult(
        state: accessMode == nil ? .unknown : .ready,
        exists: true,
        grantedAccessMode: accessMode,
        expiresAt: expiresAt,
        hasRefreshToken: hasRefreshToken
    )
}

private func invalidTokenResult() -> TokenInspectionResult {
    TokenInspectionResult(
        state: .invalid,
        exists: true,
        grantedAccessMode: nil,
        expiresAt: nil,
        hasRefreshToken: false
    )
}

private func executeReaderGraphQL(config: MailGatewayConfig, query: String) throws -> (body: [String: Any], exitCode: MailGatewayExitCode) {
    let service = MailGatewayReaderService(config: config)
    do {
        let data: [String: Any]
        if fieldExists("accounts", in: query) {
            data = ["accounts": service.graphQLAccounts()]
        } else if fieldExists("account", in: query) {
            data = ["account": service.graphQLAccount(id: try extractStringArgument("id", from: query)) as Any? ?? NSNull()]
        } else if fieldExists("threads", in: query) {
            let accountId = try extractStringArgument("accountId", from: query)
            data = ["threads": try service.searchThreads(accountId: accountId)]
        } else if fieldExists("thread", in: query) {
            data = ["thread": try service.getThread(accountId: try extractStringArgument("accountId", from: query), threadId: try extractStringArgument("threadId", from: query))]
        } else if fieldExists("message", in: query) {
            data = ["message": try service.getMessage(accountId: try extractStringArgument("accountId", from: query), messageId: try extractStringArgument("messageId", from: query))]
        } else if fieldExists("attachment", in: query) {
            data = [
                "attachment": projectAttachmentSelection(
                    try service.getAttachment(
                        accountId: extractStringArgument("accountId", from: query),
                        messageId: extractStringArgument("messageId", from: query),
                        attachmentId: extractStringArgument("attachmentId", from: query)
                    ),
                    query: query
                )
            ]
        } else {
            throw MailGatewayError(
                "Unsupported GraphQL query",
                code: .invalidArgument,
                exitCode: .graphqlExecutionError
            )
        }
        return (["data": data], .success)
    } catch let error as MailGatewayError where error.exitCode == .graphqlExecutionError {
        let extensions: [String: Any] = [
            "code": error.code.rawValue,
            "exitCode": error.exitCode.rawValue
        ]
        let errors: [[String: Any]] = [[
            "message": error.message,
            "extensions": extensions
        ]]
        return ([
            "data": NSNull(),
            "errors": errors
        ], .graphqlExecutionError)
    }
}

private func projectAttachmentSelection(_ attachment: Any, query: String) -> Any {
    guard var object = attachment as? [String: Any] else {
        return attachment
    }
    if !query.contains("mimeType") {
        object.removeValue(forKey: "mimeType")
    }
    if !query.contains("sizeBytes") {
        object.removeValue(forKey: "sizeBytes")
    }
    if !query.contains("filename") {
        object.removeValue(forKey: "filename")
    }
    return object
}

private func parseArguments(_ arguments: [String]) throws -> ParsedArgs {
    var positionals: [String] = []
    var flags: [String: StringOrBool] = [:]
    let booleanFlags: Set<String> = ["all", "pretty"]
    var index = 0

    while index < arguments.count {
        let token = arguments[index]
        if !token.hasPrefix("--") {
            positionals.append(token)
            index += 1
            continue
        }

        let flagBody = String(token.dropFirst(2))
        guard !flagBody.isEmpty else {
            throw MailGatewayError(
                "Invalid empty flag",
                code: .invalidArgument,
                exitCode: .invalidCliUsage
            )
        }

        let split = flagBody.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(split[0])
        if split.count == 2 {
            flags[key] = .string(String(split[1]))
            index += 1
            continue
        }

        let next = index + 1 < arguments.count ? arguments[index + 1] : nil
        if booleanFlags.contains(key),
           (next == nil || (next != "true" && next != "false")) {
            flags[key] = .bool(true)
            index += 1
            continue
        }

        if let next,
           !next.hasPrefix("--") {
            flags[key] = .string(next)
            index += 2
            continue
        }

        flags[key] = .bool(true)
        index += 1
    }

    return ParsedArgs(positionals: positionals, flags: flags)
}

private func getStringFlag(_ flags: [String: StringOrBool], _ name: String) throws -> String? {
    guard let value = flags[name] else {
        return nil
    }
    switch value {
    case .string(let value):
        return value
    case .bool:
        throw MailGatewayError(
            "--\(name) requires a value",
            code: .invalidArgument,
            exitCode: .invalidCliUsage
        )
    }
}

private func getBooleanFlag(_ flags: [String: StringOrBool], _ name: String) throws -> Bool {
    guard let value = flags[name] else {
        return false
    }
    switch value {
    case .bool(let value):
        return value
    case .string("true"):
        return true
    case .string("false"):
        return false
    case .string:
        throw MailGatewayError(
            "--\(name) accepts only true or false when given a value",
            code: .invalidArgument,
            exitCode: .invalidCliUsage
        )
    }
}

private func loadQuery(flags: [String: StringOrBool]) throws -> String {
    let inlineQuery = try getStringFlag(flags, "query")
    let queryFile = try getStringFlag(flags, "query-file")
    if (inlineQuery == nil) == (queryFile == nil) {
        throw MailGatewayError(
            "Exactly one of --query or --query-file is required",
            code: .invalidArgument,
            exitCode: .invalidCliUsage
        )
    }
    if let inlineQuery {
        return inlineQuery
    }
    let path = queryFile!
    do {
        return try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        throw MailGatewayError(
            "Failed to read GraphQL query file: \(path)",
            code: .invalidArgument,
            exitCode: .invalidCliUsage,
            details: ["cause": error.localizedDescription]
        )
    }
}

private func loadVariables(flags: [String: StringOrBool]) throws -> [String: Any] {
    let inlineVariables = try getStringFlag(flags, "variables")
    let variablesFile = try getStringFlag(flags, "variables-file")
    if inlineVariables != nil && variablesFile != nil {
        throw MailGatewayError(
            "Use only one of --variables or --variables-file",
            code: .invalidArgument,
            exitCode: .invalidCliUsage
        )
    }
    if let inlineVariables {
        return try parseJsonObject(
            inlineVariables,
            invalidJsonMessage: "--variables must be valid JSON",
            invalidObjectMessage: "--variables must be a JSON object"
        )
    }
    if let variablesFile {
        do {
            let source = try String(contentsOfFile: variablesFile, encoding: .utf8)
            return try parseJsonObject(
                source,
                invalidJsonMessage: "Failed to parse JSON variables file: \(variablesFile)",
                invalidObjectMessage: "JSON variables file must contain an object: \(variablesFile)"
            )
        } catch let error as MailGatewayError {
            throw error
        } catch {
            throw MailGatewayError(
                "Failed to read JSON variables file: \(variablesFile)",
                code: .invalidArgument,
                exitCode: .invalidCliUsage,
                details: ["cause": error.localizedDescription]
            )
        }
    }
    return [:]
}

private func parseJsonObject(
    _ source: String,
    invalidJsonMessage: String,
    invalidObjectMessage: String
) throws -> [String: Any] {
    let value: Any
    do {
        value = try JSONSerialization.jsonObject(with: Data(source.utf8))
    } catch {
        throw MailGatewayError(
            invalidJsonMessage,
            code: .invalidArgument,
            exitCode: .invalidCliUsage,
            details: ["cause": error.localizedDescription]
        )
    }
    guard let object = value as? [String: Any] else {
        throw MailGatewayError(
            invalidObjectMessage,
            code: .invalidArgument,
            exitCode: .invalidCliUsage
        )
    }
    return object
}

private struct ParsedToml {
    var storage: [String: Any]?
    var credentials: [[String: Any]]
    var accounts: [[String: Any]]
}

private func parseTomlSubset(_ source: String) throws -> ParsedToml {
    var parsed = ParsedToml(storage: nil, credentials: [], accounts: [])
    var section = TomlSection.none

    for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") {
            continue
        }
        if line == "[storage]" {
            parsed.storage = parsed.storage ?? [:]
            section = .storage
            continue
        }
        if line == "[[credentials]]" {
            parsed.credentials.append([:])
            section = .credential(parsed.credentials.count - 1)
            continue
        }
        if line == "[[accounts]]" {
            parsed.accounts.append([:])
            section = .account(parsed.accounts.count - 1)
            continue
        }
        guard let equals = line.firstIndex(of: "=") else {
            throw configError("config contains an unsupported TOML line: \(line)")
        }
        let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = try parseTomlValue(rawValue)
        switch section {
        case .storage:
            parsed.storage?[key] = value
        case .credential(let index):
            parsed.credentials[index][key] = value
        case .account(let index):
            parsed.accounts[index][key] = value
        case .none:
            throw configError("config key appears outside a supported section: \(key)")
        }
    }

    return parsed
}

private func parseTomlValue(_ rawValue: String) throws -> Any {
    if rawValue.hasPrefix("\""),
       rawValue.hasSuffix("\"") {
        return String(rawValue.dropFirst().dropLast())
    }
    if rawValue.hasPrefix("["),
       rawValue.hasSuffix("]") {
        let inner = String(rawValue.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.isEmpty {
            return [String]()
        }
        return try splitTomlArray(inner).map { item in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("\""),
                  trimmed.hasSuffix("\"") else {
                throw configError("array values must be strings")
            }
            return String(trimmed.dropFirst().dropLast())
        }
    }
    throw configError("config contains an unsupported TOML value: \(rawValue)")
}

private func splitTomlArray(_ source: String) -> [String] {
    var values: [String] = []
    var current = ""
    var inString = false
    var escaping = false
    for character in source {
        if escaping {
            current.append(character)
            escaping = false
            continue
        }
        if character == "\\" {
            current.append(character)
            escaping = true
            continue
        }
        if character == "\"" {
            inString.toggle()
            current.append(character)
            continue
        }
        if character == ",",
           !inString {
            values.append(current)
            current = ""
            continue
        }
        current.append(character)
    }
    if !current.isEmpty {
        values.append(current)
    }
    return values
}

private func parseStorageConfig(_ record: [String: Any], configPath: String) throws -> StorageConfig {
    StorageConfig(
        cacheDir: try resolveConfigRelativePath(configPath: configPath, rawPath: readString(record["cache_dir"], "storage.cache_dir")),
        attachmentDir: try resolveConfigRelativePath(configPath: configPath, rawPath: readString(record["attachment_dir"], "storage.attachment_dir")),
        allowedSendAttachmentRoots: try readOptionalStringArray(record["allowed_send_attachment_roots"], "storage.allowed_send_attachment_roots")
            .map { try resolveConfigRelativePath(configPath: configPath, rawPath: $0) }
    )
}

private func parseCredentialConfig(
    _ record: [String: Any],
    index: Int,
    configPath: String,
    environment: [String: String]
) throws -> CredentialConfig {
    let contextBase = "credentials[\(index)]"
    let credentialId = try readString(record["id"], "\(contextBase).id")
    return CredentialConfig(
        id: credentialId,
        provider: try readProvider(record["provider"], "\(contextBase).provider"),
        accessMode: try readAccessMode(record["access_mode"], "\(contextBase).access_mode"),
        oauthClientSecretPath: try resolveCredentialPath(
            configPath: configPath,
            credentialId: credentialId,
            pathKey: "oauth_client_secret_path",
            configValue: readOptionalString(record["oauth_client_secret_path"], "\(contextBase).oauth_client_secret_path"),
            environment: environment,
            context: "\(contextBase).oauth_client_secret_path"
        ),
        tokenStorePath: try resolveCredentialPath(
            configPath: configPath,
            credentialId: credentialId,
            pathKey: "token_store_path",
            configValue: readOptionalString(record["token_store_path"], "\(contextBase).token_store_path"),
            environment: environment,
            context: "\(contextBase).token_store_path"
        )
    )
}

private func parseAccountConfig(_ record: [String: Any], index: Int) throws -> AccountConfig {
    let contextBase = "accounts[\(index)]"
    let emailAddress = try readString(record["email_address"], "\(contextBase).email_address")
    if !emailAddress.contains("@") {
        throw configError("\(contextBase).email_address must contain @")
    }
    return AccountConfig(
        id: try readString(record["id"], "\(contextBase).id"),
        provider: try readProvider(record["provider"], "\(contextBase).provider"),
        emailAddress: emailAddress,
        credentialId: try readString(record["credential_id"], "\(contextBase).credential_id"),
        defaultLabelIds: try readOptionalStringArray(record["default_label_ids"], "\(contextBase).default_label_ids")
    )
}

private func resolveCredentialPath(
    configPath: String,
    credentialId: String,
    pathKey: String,
    configValue: String?,
    environment: [String: String],
    context: String
) throws -> String {
    let envName = MailGatewayConfigLoader.getCredentialPathEnvVarName(credentialId: credentialId, pathKey: pathKey)
    let selected = nonBlank(environment[envName]) ?? configValue
    guard let selected else {
        throw configError("\(context) must be set in config or \(envName)")
    }
    return try resolveConfigRelativePath(configPath: configPath, rawPath: selected)
}

private func resolveConfigRelativePath(configPath: String, rawPath: String) throws -> String {
    if rawPath.hasPrefix("/") {
        return normalizedPath(rawPath)
    }
    let configDirectory = URL(fileURLWithPath: configPath).deletingLastPathComponent()
    return normalizedPath(configDirectory.appendingPathComponent(rawPath).path)
}

private func readProvider(_ value: Any?, _ context: String) throws -> MailProvider {
    let provider = try readString(value, context)
    guard let parsed = MailProvider(rawValue: provider) else {
        throw configError("\(context) must currently be \"gmail\"")
    }
    return parsed
}

private func readAccessMode(_ value: Any?, _ context: String) throws -> AccessMode {
    let raw = value == nil ? "read" : try readString(value, context)
    guard let parsed = AccessMode(rawValue: raw) else {
        throw configError("\(context) must be \"read\" or \"read_send\"")
    }
    return parsed
}

private func readString(_ value: Any?, _ context: String) throws -> String {
    guard let string = value as? String,
          !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw configError("\(context) must be a non-empty string")
    }
    return string
}

private func readOptionalString(_ value: Any?, _ context: String) throws -> String? {
    guard value != nil else {
        return nil
    }
    return try readString(value, context)
}

private func readOptionalStringArray(_ value: Any?, _ context: String) throws -> [String] {
    guard value != nil else {
        return []
    }
    guard let values = value as? [String] else {
        throw configError("\(context) must be an array of strings")
    }
    for (index, item) in values.enumerated() where item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw configError("\(context)[\(index)] must be a non-empty string")
    }
    return values
}

private func ensureUnique(_ values: [String], context: String) throws {
    var seen: Set<String> = []
    for value in values {
        if seen.contains(value) {
            throw configError("\(context) contains a duplicate value: \(value)")
        }
        seen.insert(value)
    }
}

private func validateAccountCredentialLinks(credentials: [CredentialConfig], accounts: [AccountConfig]) throws {
    let credentialsById = Dictionary(uniqueKeysWithValues: credentials.map { ($0.id, $0) })
    for account in accounts {
        guard let credential = credentialsById[account.credentialId] else {
            throw configError("accounts.\(account.id) references unknown credential: \(account.credentialId)")
        }
        if credential.provider != account.provider {
            throw configError("accounts.\(account.id) provider does not match credential provider")
        }
    }
}

private func configError(_ message: String) -> MailGatewayError {
    MailGatewayError(message, code: .configInvalid, exitCode: .configurationError)
}

private func nonBlank(_ value: String?) -> String? {
    guard let value else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func normalizedPath(_ path: String) -> String {
    let expanded = NSString(string: path).expandingTildeInPath
    let isAbsolute = expanded.hasPrefix("/")
    var parts: [String] = []
    for component in expanded.split(separator: "/", omittingEmptySubsequences: true) {
        if component == "." {
            continue
        }
        if component == ".." {
            if !parts.isEmpty {
                parts.removeLast()
            }
            continue
        }
        parts.append(String(component))
    }
    let normalized = parts.joined(separator: "/")
    if isAbsolute {
        return "/" + normalized
    }
    return normalized.isEmpty ? "." : normalized
}

private func isWithinRoot(rootPath: String, candidatePath: String) -> Bool {
    let root = normalizedPath(rootPath)
    let candidate = normalizedPath(candidatePath)
    return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
}

private func parseDate(_ value: String) -> Date? {
    if let date = ISO8601DateFormatter().date(from: value) {
        return date
    }
    return nil
}

private func fieldExists(_ field: String, in query: String) -> Bool {
    guard let range = query.range(of: field) else {
        return false
    }
    let before = range.lowerBound > query.startIndex ? query[query.index(before: range.lowerBound)] : " "
    let after = range.upperBound < query.endIndex ? query[range.upperBound] : " "
    return !isGraphQLIdentifier(before) && !isGraphQLIdentifier(after)
}

private func isGraphQLIdentifier(_ character: Character) -> Bool {
    character == "_" || character.isLetter || character.isNumber
}

private func extractStringArgument(_ name: String, from query: String) throws -> String {
    let needle = "\(name):"
    guard let range = query.range(of: needle) else {
        throw MailGatewayError(
            "Missing GraphQL argument: \(name)",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    var index = range.upperBound
    while index < query.endIndex,
          query[index].isWhitespace {
        index = query.index(after: index)
    }
    guard index < query.endIndex,
          query[index] == "\"" else {
        throw MailGatewayError(
            "GraphQL argument \(name) must be a string literal",
            code: .invalidArgument,
            exitCode: .graphqlExecutionError
        )
    }
    index = query.index(after: index)
    var value = ""
    var escaping = false
    while index < query.endIndex {
        let character = query[index]
        if escaping {
            value.append(character)
            escaping = false
        } else if character == "\\" {
            escaping = true
        } else if character == "\"" {
            return value
        } else {
            value.append(character)
        }
        index = query.index(after: index)
    }
    throw MailGatewayError(
        "GraphQL argument \(name) string literal is unterminated",
        code: .invalidArgument,
        exitCode: .graphqlExecutionError
    )
}

private func errorOutput(_ error: MailGatewayError) -> [String: Any] {
    var payload: [String: Any] = [
        "message": error.message,
        "code": error.code.rawValue,
        "exitCode": error.exitCode.rawValue
    ]
    if !error.details.isEmpty {
        payload["details"] = error.details
    }
    return ["error": payload]
}

private func jsonString(_ payload: Any, pretty: Bool) -> String {
    let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload, options: options),
          let text = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return text
}
