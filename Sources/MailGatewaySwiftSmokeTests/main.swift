import Foundation
import MailGatewayCore

func runSmokeTests() throws {
    var cleanup: [String] = []
    defer {
        for path in cleanup {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    try testRelativeConfig(cleanup: &cleanup)
    try testCredentialEnvFallback(cleanup: &cleanup)
    try testCredentialEnvOverride(cleanup: &cleanup)
    try testPrettyConfigValidation(cleanup: &cleanup)
    try testEnvOnlyConfigValidation(cleanup: &cleanup)
    try testMissingAuthStatus(cleanup: &cleanup)
    try testScopeMismatchAuthStatus(cleanup: &cleanup)
    try testRevokeMissingToken(cleanup: &cleanup)
    try testAccountsGraphQL(cleanup: &cleanup)
    try testInvalidInlineVariables(cleanup: &cleanup)
    try testInvalidVariablesFile(cleanup: &cleanup)
    try testMissingQueryFile(cleanup: &cleanup)
    try testAttachmentLookup(cleanup: &cleanup)
    try testMessageFileDownload(cleanup: &cleanup)
    try testMissingAccountGraphQLError(cleanup: &cleanup)
    try testAccountCachePrune(cleanup: &cleanup)
    try testInvalidCachePruneOptions(cleanup: &cleanup)
}

func testRelativeConfig(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let config = try MailGatewayConfigLoader.loadConfig(configPath: fixture.configPath, environment: [:])
    try assert(config.storage.attachmentDir == fixture.attachmentRoot, "relative attachment path should resolve")
    try assert(config.storage.allowedSendAttachmentRoots == [fixture.sendRoot], "send root should resolve")
    try assert(config.credentials.first?.accessMode == .read, "access mode should parse")
}

func testCredentialEnvFallback(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup, includeCredentialPaths: false)
    let config = try MailGatewayConfigLoader.loadConfig(
        configPath: fixture.configPath,
        environment: credentialEnv(fixture: fixture)
    )
    try assert(
        config.credentials.first?.oauthClientSecretPath == fixture.clientSecretPath,
        "env oauth path should load"
    )
    try assert(config.credentials.first?.tokenStorePath == fixture.tokenPath, "env token path should load")
}

func testCredentialEnvOverride(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let alternateSecretsDir = URL(fileURLWithPath: fixture.rootDir)
        .appendingPathComponent("alt-secrets", isDirectory: true)
        .path
    let alternateTokensDir = URL(fileURLWithPath: fixture.rootDir)
        .appendingPathComponent("alt-tokens", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: alternateSecretsDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: alternateTokensDir, withIntermediateDirectories: true)

    let alternateClientSecretPath = URL(fileURLWithPath: alternateSecretsDir)
        .appendingPathComponent("client.json")
        .path
    let alternateTokenPath = URL(fileURLWithPath: alternateTokensDir)
        .appendingPathComponent("account.json")
        .path
    try writeText(alternateClientSecretPath, "{\"installed\":true}\n")
    let config = try MailGatewayConfigLoader.loadConfig(
        configPath: fixture.configPath,
        environment: credentialEnv(
            fixture: fixture,
            oauthPath: alternateClientSecretPath,
            tokenPath: alternateTokenPath
        )
    )
    try assert(
        config.credentials.first?.oauthClientSecretPath == alternateClientSecretPath,
        "env oauth path should override TOML"
    )
    try assert(config.credentials.first?.tokenStorePath == alternateTokenPath, "env token path should override TOML")
}

func testPrettyConfigValidation(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli(["--pretty", "config", "validate", "--config", fixture.configPath])
    try assert(result.exitCode == 0, "pretty config validation should succeed")
    try assert(
        containsEither(result.stdout, "\n  \"ok\" : true", "\n  \"ok\": true"),
        "pretty output should contain ok"
    )
}

func testEnvOnlyConfigValidation(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup, includeCredentialPaths: false)
    var env = credentialEnv(fixture: fixture)
    env["MAIL_GATEWAY_CONFIG"] = fixture.configPath
    let result = runCli(["config", "validate", "--config", fixture.configPath], env: env)
    try assert(result.exitCode == 0, "CLI config validation should use provided env")
    try assert(result.stderr.isEmpty, "env-only CLI config validation should not write stderr")
}

func testMissingAuthStatus(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli(["auth", "status", "--config", fixture.configPath, "--credential", "gmail-personal"])
    try assert(result.exitCode == 0, "auth status should succeed")
    let output = try decodeObject(result.stdout)
    try assert(output["state"] as? String == "MISSING", "missing token state should be reported")
    try assert(output["tokenStoreExists"] as? Bool == false, "missing token existence should be false")
}

func testScopeMismatchAuthStatus(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    try writeText(fixture.tokenPath, #"{"accessMode":"read_send","refreshToken":"refresh-token"}"#)
    let result = runCli(["auth", "status", "--config", fixture.configPath, "--credential", "gmail-personal"])
    let output = try decodeObject(result.stdout)
    try assert(output["state"] as? String == "SCOPE_MISMATCH", "scope mismatch should be reported")
    try assert(output["grantedAccessMode"] as? String == "read_send", "granted mode should be read_send")
}

func testRevokeMissingToken(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli(["auth", "revoke", "--config", fixture.configPath, "--credential", "gmail-personal"])
    try assert(result.exitCode == 0, "revoke missing token should succeed")
    let output = try decodeObject(result.stdout)
    try assert(output["revoked"] as? Bool == false, "missing token revoke should be false")
}

func testAccountsGraphQL(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { accounts { id provider emailAddress capabilities \
        { canRead canSend configuredAccessMode authState } } }
        """
    ])
    try assert(result.exitCode == 0, "accounts GraphQL query should succeed")
    let output = try decodeObject(result.stdout)
    let data = output["data"] as? [String: Any]
    let account = (data?["accounts"] as? [[String: Any]])?.first
    try assert(account?["provider"] as? String == "GMAIL", "GraphQL provider should be uppercased")
    let capabilities = account?["capabilities"] as? [String: Any]
    try assert(
        capabilities?["configuredAccessMode"] as? String == "READ",
        "GraphQL access mode should be uppercased"
    )
    try assert(capabilities?["authState"] as? String == "MISSING", "GraphQL auth state should be missing")
}

func testInvalidInlineVariables(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", "{ accounts { id } }",
        "--variables", "{bad-json}"
    ])
    try assert(result.exitCode == 2, "invalid inline variables should be CLI usage error")
    try assert(result.stderr.contains("--variables must be valid JSON"), "invalid variables error should be explained")
}

func testInvalidVariablesFile(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let variablesPath = URL(fileURLWithPath: fixture.rootDir).appendingPathComponent("variables.json").path
    try writeText(variablesPath, "{bad-json}")
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", "{ accounts { id } }",
        "--variables-file", variablesPath
    ])
    try assert(result.exitCode == 2, "invalid variables file should be CLI usage error")
    try assert(
        result.stderr.contains("Failed to parse JSON variables file"),
        "invalid variables file error should be explained"
    )
}

func testMissingQueryFile(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let queryPath = URL(fileURLWithPath: fixture.rootDir).appendingPathComponent("missing.graphql").path
    let result = runCli(["graphql", "--config", fixture.configPath, "--query-file", queryPath])
    try assert(result.exitCode == 2, "missing query file should be CLI usage error")
    try assert(
        result.stderr.contains("Failed to read GraphQL query file"),
        "missing query file error should be explained"
    )
}

func testAttachmentLookup(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let messageDir = URL(fileURLWithPath: fixture.attachmentRoot)
        .appendingPathComponent("personal", isDirectory: true)
        .appendingPathComponent("message-1", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: messageDir, withIntermediateDirectories: true)
    let attachmentPath = URL(fileURLWithPath: messageDir)
        .appendingPathComponent("attachment-1-report.pdf")
        .path
    try writeText(attachmentPath, "payload")
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { attachment(accountId: "personal", messageId: "message-1", attachmentId: "attachment-1") \
        { id filename localPath materializationState } }
        """
    ])
    try assert(result.exitCode == 0, "attachment GraphQL query should succeed")
    try assert(
        containsEither(result.stdout, #""filename":"report.pdf""#, #""filename" : "report.pdf""#),
        "attachment filename should project"
    )
    try assert(
        containsEither(result.stdout, #""materializationState":"CACHED""#, #""materializationState" : "CACHED""#),
        "attachment state should be cached"
    )
}

func testMessageFileDownload(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let materializedDir = URL(fileURLWithPath: fixture.attachmentRoot)
        .appendingPathComponent("personal", isDirectory: true)
        .appendingPathComponent("message-2", isDirectory: true)
    try writeMessageFiles(in: materializedDir)
    let lookupResult = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", """
        { messageFileSet(accountId: "personal", messageId: "message-2") \
        { hasFiles files { kind filename hasPayload downloadKey materializationState } } }
        """
    ])
    try assertMessageFileLookup(lookupResult)
    let bodyDownloadKey = try downloadKey(kind: "BODY_TEXT", from: lookupResult)
    try assertDownloadedFile(
        downloadKey: bodyDownloadKey,
        fixture: fixture,
        expectedKind: "BODY_TEXT",
        expectedContents: "private body payload"
    )
    let temporaryDownloadKey = try downloadKey(kind: "TEMPORARY_FILE", from: lookupResult)
    try assertDownloadedFile(
        downloadKey: temporaryDownloadKey,
        fixture: fixture,
        expectedKind: "TEMPORARY_FILE",
        expectedContents: "temporary payload"
    )
}

func writeMessageFiles(in materializedDir: URL) throws {
    try writeText(materializedDir.appendingPathComponent("body.txt").path, "private body payload")
    try writeText(materializedDir.appendingPathComponent("body.html").path, "<p>private html payload</p>")
    try writeText(materializedDir
        .appendingPathComponent("temp", isDirectory: true)
        .appendingPathComponent("tmp-1-report.txt")
        .path, "temporary payload")
}

func assertMessageFileLookup(_ result: MailGatewayCommandResult) throws {
    try assert(result.exitCode == 0, "message file set lookup should succeed")
    try assert(!result.stdout.contains("private body payload"), "GraphQL output should not include text body payload")
    try assert(!result.stdout.contains("private html payload"), "GraphQL output should not include HTML body payload")
    try assert(!result.stdout.contains("temporary payload"), "GraphQL output should not include temporary file payload")
    try assert(!result.stdout.contains("localPath"), "GraphQL metadata should not expose local payload paths")
    try assert(!result.stdout.contains("directory"), "GraphQL metadata should not expose local payload directories")
    try assert(
        containsEither(result.stdout, #""kind":"BODY_TEXT""#, #""kind" : "BODY_TEXT""#),
        "lookup should include text body file metadata"
    )
    try assert(
        containsEither(result.stdout, #""kind":"BODY_HTML""#, #""kind" : "BODY_HTML""#),
        "lookup should include HTML body file metadata"
    )
    try assert(
        containsEither(result.stdout, #""kind":"TEMPORARY_FILE""#, #""kind" : "TEMPORARY_FILE""#),
        "lookup should include temporary file metadata"
    )
}

func downloadKey(kind: String, from result: MailGatewayCommandResult) throws -> String {
    let lookup = try decodeObject(result.stdout)
    let data = lookup["data"] as? [String: Any]
    let fileSet = data?["messageFileSet"] as? [String: Any]
    let files = fileSet?["files"] as? [[String: Any]]
    let matchingFile = files?.first { $0["kind"] as? String == kind }
    guard let downloadKey = matchingFile?["downloadKey"] as? String else {
        throw SmokeTestFailure.assertionFailed("\(kind) file should include a download key")
    }
    return downloadKey
}

func assertDownloadedFile(
    downloadKey: String,
    fixture: Fixture,
    expectedKind: String,
    expectedContents: String
) throws {
    let downloadDir = URL(fileURLWithPath: fixture.cacheRoot)
        .appendingPathComponent("downloads", isDirectory: true)
        .path
    let downloadResult = runCli([
        "file", "download",
        "--config", fixture.configPath,
        "--key", downloadKey,
        "--output-dir", downloadDir
    ])
    try assert(downloadResult.exitCode == 0, "file download command should succeed")
    let download = try decodeObject(downloadResult.stdout)
    guard let downloadedPath = download["localPath"] as? String else {
        throw SmokeTestFailure.assertionFailed("file download should return localPath")
    }
    try assert(download["kind"] as? String == expectedKind, "downloaded file kind should match")
    let downloadedContents = try? String(contentsOfFile: downloadedPath, encoding: .utf8)
    try assert(downloadedContents == expectedContents, "downloaded file payload should match")
}

func testMissingAccountGraphQLError(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli([
        "graphql",
        "--config", fixture.configPath,
        "--query", #"{ threads(input: { accountId: "missing-account" }) { totalCount } }"#
    ])
    try assert(result.exitCode == 5, "missing account GraphQL query should fail with GraphQL exit")
    try assert(result.stdout.contains("Unknown account: missing-account"), "GraphQL error should include app error")
    try assert(result.stdout.contains("ACCOUNT_NOT_FOUND"), "GraphQL error should include code")
}

func testAccountCachePrune(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let accountDir = URL(fileURLWithPath: fixture.attachmentRoot)
        .appendingPathComponent("personal", isDirectory: true)
        .path
    let otherDir = URL(fileURLWithPath: fixture.attachmentRoot)
        .appendingPathComponent("other", isDirectory: true)
        .path
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

func testInvalidCachePruneOptions(cleanup: inout [String]) throws {
    let fixture = try trackedFixture(cleanup: &cleanup)
    let result = runCli(["cache", "prune", "--config", fixture.configPath, "--all", "--account", "personal"])
    try assert(result.exitCode == 2, "combining --all and --account should fail")
    try assert(
        result.stderr.contains("cache prune accepts either --all or --account"),
        "cache prune error should be explained"
    )
}

do {
    try runSmokeTests()
    print("MailGateway Swift smoke tests passed")
} catch {
    FileHandle.standardError.write(Data("Smoke test failure: \(error)\n".utf8))
    exit(1)
}
