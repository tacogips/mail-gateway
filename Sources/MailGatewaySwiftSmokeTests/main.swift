import Foundation
import MailGatewayCore

enum SmokeTestFailure: Error, CustomStringConvertible {
    case assertionFailed(String)

    var description: String {
        switch self {
        case .assertionFailed(let message):
            return message
        }
    }
}

struct Fixture {
    let clientSecretPath: String
    let rootDir: String
    let configPath: String
    let attachmentRoot: String
    let sendRoot: String
    let tokenPath: String
}

func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw SmokeTestFailure.assertionFailed(message)
    }
}

func writeText(_ path: String, _ text: String) throws {
    try FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
        withIntermediateDirectories: true
    )
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}

func createFixture(
    includeCredentialPaths: Bool = true,
    oauthClientSecretPathValue: String? = nil,
    tokenStorePathValue: String? = nil
) throws -> Fixture {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mail-gateway-\(UUID().uuidString)", isDirectory: true)
    let rootDir = root.path
    let configDir = root.appendingPathComponent("config", isDirectory: true).path
    let cacheDir = root.appendingPathComponent("cache", isDirectory: true).path
    let attachmentRoot = root.appendingPathComponent("attachments", isDirectory: true).path
    let sendRoot = root.appendingPathComponent("send", isDirectory: true).path
    let secretsDir = root.appendingPathComponent("secrets", isDirectory: true).path
    let tokensDir = root.appendingPathComponent("tokens", isDirectory: true).path
    for directory in [configDir, cacheDir, attachmentRoot, sendRoot, secretsDir, tokensDir] {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    let clientSecretPath = URL(fileURLWithPath: secretsDir).appendingPathComponent("client.json").path
    let tokenPath = URL(fileURLWithPath: tokensDir).appendingPathComponent("account.json").path
    try writeText(clientSecretPath, "{\"installed\":true}\n")

    let configPath = URL(fileURLWithPath: configDir).appendingPathComponent("config.toml").path
    let credentialLines = includeCredentialPaths
        ? """
        oauth_client_secret_path = "\(oauthClientSecretPathValue ?? "../secrets/client.json")"
        token_store_path = "\(tokenStorePathValue ?? "../tokens/account.json")"
        """
        : ""
    try writeText(
        configPath,
        """
        [storage]
        cache_dir = "../cache"
        attachment_dir = "../attachments"
        allowed_send_attachment_roots = ["../send"]

        [[credentials]]
        id = "gmail-personal"
        provider = "gmail"
        access_mode = "read"
        \(credentialLines)

        [[accounts]]
        id = "personal"
        provider = "gmail"
        email_address = "person@example.com"
        credential_id = "gmail-personal"
        default_label_ids = ["INBOX"]
        """
    )

    return Fixture(
        clientSecretPath: clientSecretPath,
        rootDir: rootDir,
        configPath: configPath,
        attachmentRoot: attachmentRoot,
        sendRoot: sendRoot,
        tokenPath: tokenPath
    )
}

func decodeObject(_ text: String) throws -> [String: Any] {
    let data = Data(text.utf8)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SmokeTestFailure.assertionFailed("expected JSON object")
    }
    return object
}

func runCli(_ arguments: [String], env: [String: String] = [:]) -> MailGatewayCommandResult {
    MailGatewayCLI().run(arguments: arguments, environment: env)
}

func credentialEnv(fixture: Fixture, oauthPath: String? = nil, tokenPath: String? = nil) -> [String: String] {
    [
        MailGatewayConfigLoader.getCredentialPathEnvVarName(
            credentialId: "gmail-personal",
            pathKey: "oauth_client_secret_path"
        ): oauthPath ?? fixture.clientSecretPath,
        MailGatewayConfigLoader.getCredentialPathEnvVarName(
            credentialId: "gmail-personal",
            pathKey: "token_store_path"
        ): tokenPath ?? fixture.tokenPath
    ]
}

func runSmokeTests() throws {
    var cleanup: [String] = []
    defer {
        for path in cleanup {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    do {
        let fixture = try createFixture()
        cleanup.append(fixture.rootDir)
        let config = try MailGatewayConfigLoader.loadConfig(configPath: fixture.configPath, environment: [:])
        try assert(config.storage.attachmentDir == fixture.attachmentRoot, "relative attachment path should resolve")
        try assert(config.storage.allowedSendAttachmentRoots == [fixture.sendRoot], "send root should resolve")
        try assert(config.credentials.first?.accessMode == .read, "access mode should parse")
    }

    do {
        let fixture = try createFixture(includeCredentialPaths: false)
        cleanup.append(fixture.rootDir)
        let config = try MailGatewayConfigLoader.loadConfig(
            configPath: fixture.configPath,
            environment: credentialEnv(fixture: fixture)
        )
        try assert(config.credentials.first?.oauthClientSecretPath == fixture.clientSecretPath, "env oauth path should load")
        try assert(config.credentials.first?.tokenStorePath == fixture.tokenPath, "env token path should load")
    }

    do {
        let fixture = try createFixture()
        cleanup.append(fixture.rootDir)
        let alternateSecretsDir = URL(fileURLWithPath: fixture.rootDir).appendingPathComponent("alt-secrets", isDirectory: true).path
        let alternateTokensDir = URL(fileURLWithPath: fixture.rootDir).appendingPathComponent("alt-tokens", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: alternateSecretsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: alternateTokensDir, withIntermediateDirectories: true)
        let alternateClientSecretPath = URL(fileURLWithPath: alternateSecretsDir).appendingPathComponent("client.json").path
        let alternateTokenPath = URL(fileURLWithPath: alternateTokensDir).appendingPathComponent("account.json").path
        try writeText(alternateClientSecretPath, "{\"installed\":true}\n")
        let config = try MailGatewayConfigLoader.loadConfig(
            configPath: fixture.configPath,
            environment: credentialEnv(
                fixture: fixture,
                oauthPath: alternateClientSecretPath,
                tokenPath: alternateTokenPath
            )
        )
        try assert(config.credentials.first?.oauthClientSecretPath == alternateClientSecretPath, "env oauth path should override TOML")
        try assert(config.credentials.first?.tokenStorePath == alternateTokenPath, "env token path should override TOML")
    }

    do {
        let fixture = try createFixture()
        cleanup.append(fixture.rootDir)
        let result = runCli(["--pretty", "config", "validate", "--config", fixture.configPath])
        try assert(result.exitCode == 0, "pretty config validation should succeed")
        try assert(result.stdout.contains("\n  \"ok\" : true") || result.stdout.contains("\n  \"ok\": true"), "pretty output should contain ok")
    }

    do {
        let fixture = try createFixture(includeCredentialPaths: false)
        cleanup.append(fixture.rootDir)
        var env = credentialEnv(fixture: fixture)
        env["MAIL_GATEWAY_CONFIG"] = fixture.configPath
        let result = runCli(["config", "validate", "--config", fixture.configPath], env: env)
        try assert(result.exitCode == 0, "CLI config validation should use provided env")
        try assert(result.stderr.isEmpty, "env-only CLI config validation should not write stderr")
    }

    do {
        let fixture = try createFixture()
        cleanup.append(fixture.rootDir)
        let result = runCli(["auth", "status", "--config", fixture.configPath, "--credential", "gmail-personal"])
        try assert(result.exitCode == 0, "auth status should succeed")
        let output = try decodeObject(result.stdout)
        try assert(output["state"] as? String == "MISSING", "missing token state should be reported")
        try assert(output["tokenStoreExists"] as? Bool == false, "missing token existence should be false")
    }

    do {
        let fixture = try createFixture()
        cleanup.append(fixture.rootDir)
        try writeText(fixture.tokenPath, #"{"accessMode":"read_send","refreshToken":"refresh-token"}"#)
        let result = runCli(["auth", "status", "--config", fixture.configPath, "--credential", "gmail-personal"])
        let output = try decodeObject(result.stdout)
        try assert(output["state"] as? String == "SCOPE_MISMATCH", "scope mismatch should be reported")
        try assert(output["grantedAccessMode"] as? String == "read_send", "granted mode should be read_send")
    }

    do {
        let fixture = try createFixture()
        cleanup.append(fixture.rootDir)
        let result = runCli(["auth", "revoke", "--config", fixture.configPath, "--credential", "gmail-personal"])
        try assert(result.exitCode == 0, "revoke missing token should succeed")
        let output = try decodeObject(result.stdout)
        try assert(output["revoked"] as? Bool == false, "missing token revoke should be false")
    }

    do {
        let fixture = try createFixture()
        cleanup.append(fixture.rootDir)
        let result = runCli([
            "graphql",
            "--config", fixture.configPath,
            "--query", "{ accounts { id provider emailAddress capabilities { canRead canSend configuredAccessMode authState } } }"
        ])
        try assert(result.exitCode == 0, "accounts GraphQL query should succeed")
        let output = try decodeObject(result.stdout)
        let data = output["data"] as? [String: Any]
        let accounts = data?["accounts"] as? [[String: Any]]
        let account = accounts?.first
        try assert(account?["provider"] as? String == "GMAIL", "GraphQL provider should be uppercased")
        let capabilities = account?["capabilities"] as? [String: Any]
        try assert(capabilities?["configuredAccessMode"] as? String == "READ", "GraphQL access mode should be uppercased")
        try assert(capabilities?["authState"] as? String == "MISSING", "GraphQL auth state should be missing")
    }

    do {
        let fixture = try createFixture()
        cleanup.append(fixture.rootDir)
        let result = runCli([
            "graphql",
            "--config", fixture.configPath,
            "--query", "{ accounts { id } }",
            "--variables", "{bad-json}"
        ])
        try assert(result.exitCode == 2, "invalid inline variables should be CLI usage error")
        try assert(result.stderr.contains("--variables must be valid JSON"), "invalid variables error should be explained")
    }

    do {
        let fixture = try createFixture()
        cleanup.append(fixture.rootDir)
        let variablesPath = URL(fileURLWithPath: fixture.rootDir).appendingPathComponent("variables.json").path
        try writeText(variablesPath, "{bad-json}")
        let result = runCli([
            "graphql",
            "--config", fixture.configPath,
            "--query", "{ accounts { id } }",
            "--variables-file", variablesPath
        ])
        try assert(result.exitCode == 2, "invalid variables file should be CLI usage error")
        try assert(result.stderr.contains("Failed to parse JSON variables file"), "invalid variables file error should be explained")
    }

    do {
        let fixture = try createFixture()
        cleanup.append(fixture.rootDir)
        let queryPath = URL(fileURLWithPath: fixture.rootDir).appendingPathComponent("missing.graphql").path
        let result = runCli(["graphql", "--config", fixture.configPath, "--query-file", queryPath])
        try assert(result.exitCode == 2, "missing query file should be CLI usage error")
        try assert(result.stderr.contains("Failed to read GraphQL query file"), "missing query file error should be explained")
    }

    do {
        let fixture = try createFixture()
        cleanup.append(fixture.rootDir)
        let messageDir = URL(fileURLWithPath: fixture.attachmentRoot)
            .appendingPathComponent("personal", isDirectory: true)
            .appendingPathComponent("message-1", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: messageDir, withIntermediateDirectories: true)
        let attachmentPath = URL(fileURLWithPath: messageDir).appendingPathComponent("attachment-1-report.pdf").path
        try writeText(attachmentPath, "payload")
        let result = runCli([
            "graphql",
            "--config", fixture.configPath,
            "--query", #"{ attachment(accountId: "personal", messageId: "message-1", attachmentId: "attachment-1") { id filename localPath materializationState } }"#
        ])
        try assert(result.exitCode == 0, "attachment GraphQL query should succeed")
        try assert(result.stdout.contains(#""filename":"report.pdf""#) || result.stdout.contains(#""filename" : "report.pdf""#), "attachment filename should project")
        try assert(result.stdout.contains(#""materializationState":"CACHED""#) || result.stdout.contains(#""materializationState" : "CACHED""#), "attachment state should be cached")
    }

    do {
        let fixture = try createFixture()
        cleanup.append(fixture.rootDir)
        let result = runCli([
            "graphql",
            "--config", fixture.configPath,
            "--query", #"{ threads(input: { accountId: "missing-account" }) { totalCount } }"#
        ])
        try assert(result.exitCode == 5, "missing account GraphQL query should fail with GraphQL exit")
        try assert(result.stdout.contains("Unknown account: missing-account"), "GraphQL error should include app error")
        try assert(result.stdout.contains("ACCOUNT_NOT_FOUND"), "GraphQL error should include code")
    }

    do {
        let fixture = try createFixture()
        cleanup.append(fixture.rootDir)
        let accountDir = URL(fileURLWithPath: fixture.attachmentRoot).appendingPathComponent("personal", isDirectory: true).path
        let otherDir = URL(fileURLWithPath: fixture.attachmentRoot).appendingPathComponent("other", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: accountDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: otherDir, withIntermediateDirectories: true)
        try writeText(URL(fileURLWithPath: accountDir).appendingPathComponent("file.txt").path, "one")
        let otherFile = URL(fileURLWithPath: otherDir).appendingPathComponent("file.txt").path
        try writeText(otherFile, "two")
        let result = runCli(["cache", "prune", "--config", fixture.configPath, "--account", "personal"])
        try assert(result.exitCode == 0, "account cache prune should succeed")
        let output = try decodeObject(result.stdout)
        try assert((output["prunedPaths"] as? [String]) == [accountDir], "pruned path should be account directory")
        try assert((try? String(contentsOfFile: otherFile, encoding: .utf8)) == "two", "other account cache should remain")
    }

    do {
        let fixture = try createFixture()
        cleanup.append(fixture.rootDir)
        let result = runCli(["cache", "prune", "--config", fixture.configPath, "--all", "--account", "personal"])
        try assert(result.exitCode == 2, "combining --all and --account should fail")
        try assert(result.stderr.contains("cache prune accepts either --all or --account"), "cache prune error should be explained")
    }
}

do {
    try runSmokeTests()
    print("MailGateway Swift smoke tests passed")
} catch {
    FileHandle.standardError.write(Data("Smoke test failure: \(error)\n".utf8))
    exit(1)
}
