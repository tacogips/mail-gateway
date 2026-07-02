import Foundation
import Darwin
import Testing
@testable import MailGatewayCore

@Test func readerHelpUsesReaderExecutableName() {
    let result = MailGatewayCLI().run(arguments: ["--help"], environment: [:])
    #expect(result.exitCode == MailGatewayExitCode.success.rawValue)
    #expect(result.stdout.contains("mail-gateway-reader"))
}

@Test func draftHelpUsesDraftExecutableName() {
    let result = MailGatewayCLI(mode: .draftGateway).run(arguments: ["--help"], environment: [:])
    #expect(result.exitCode == MailGatewayExitCode.success.rawValue)
    #expect(result.stdout.contains("mail-gateway-draft"))
}

@Test func senderHelpUsesSenderExecutableName() {
    let result = MailGatewayCLI(mode: .directSender).run(arguments: ["--help"], environment: [:])
    #expect(result.exitCode == MailGatewayExitCode.success.rawValue)
    #expect(result.stdout.contains("mail-gateway-sender"))
}

@Test func tokenRefreshOAuthClientUsesConfiguredTokenURIAndAllowsPublicClient() throws {
    let credential = testCredential(oauthClientSecretJSON: """
        {
          "installed": {
            "client_id": " client-id ",
            "auth_uri": " https://accounts.example.test/o/oauth2/auth ",
            "token_uri": " https://tokens.example.test/token "
          }
        }
        """)

    let client = try loadGoogleOAuthClient(credential: credential, use: .tokenRefresh)

    #expect(client.clientId == "client-id")
    #expect(client.clientSecret == nil)
    #expect(client.tokenURI == "https://tokens.example.test/token")
}

@Test func tokenRefreshOAuthClientAcceptsWebClient() throws {
    let credential = testCredential(oauthClientSecretJSON: """
        {
          "web": {
            "client_id": "web-client-id",
            "client_secret": "web-secret",
            "token_uri": "https://tokens.example.test/token"
          }
        }
        """)

    let client = try loadGoogleOAuthClient(credential: credential, use: .tokenRefresh)

    #expect(client.clientId == "web-client-id")
    #expect(client.clientSecret == "web-secret")
    #expect(client.tokenURI == "https://tokens.example.test/token")
}

@Test func tokenRefreshOAuthClientRejectsWebClientWithoutSecret() throws {
    let credential = testCredential(oauthClientSecretJSON: """
        {
          "web": {
            "client_id": "web-client-id",
            "token_uri": "https://tokens.example.test/token"
          }
        }
        """)

    let error = try requireMailGatewayError {
        _ = try loadGoogleOAuthClient(credential: credential, use: .tokenRefresh)
    }

    #expect(error.code == .configInvalid)
    #expect(error.exitCode == .configurationError)
}

@Test func desktopLoginRejectsWebOnlyOAuthClient() throws {
    let credential = testCredential(oauthClientSecretJSON: """
        {
          "web": {
            "client_id": "web-client-id",
            "client_secret": "web-secret",
            "token_uri": "https://tokens.example.test/token"
          }
        }
        """)

    let error = try requireMailGatewayError {
        _ = try loadGoogleOAuthClient(credential: credential, use: .desktopLogin)
    }

    #expect(error.code == .configInvalid)
    #expect(error.exitCode == .authenticationBootstrapError)
}

@Test func malformedAccessTokenExpiryIsNotFresh() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-06-26T00:00:00Z"))

    #expect(gmailAccessTokenIsFresh(expiresAt: nil, now: now))
    #expect(!gmailAccessTokenIsFresh(expiresAt: "not-a-date", now: now))
    #expect(!gmailAccessTokenIsFresh(expiresAt: "2026-06-26T00:00:30Z", now: now, refreshLeeway: 60))
    #expect(gmailAccessTokenIsFresh(expiresAt: "2026-06-26T00:02:00Z", now: now, refreshLeeway: 60))
}

@Test func formURLEncodedEscapesReservedCharacters() {
    let encoded = formURLEncoded([
        ("redirect_uri", "http://127.0.0.1:1234/oauth2callback"),
        ("literal", "a+b c%")
    ])

    #expect(encoded == "redirect_uri=http%3A%2F%2F127.0.0.1%3A1234%2Foauth2callback&literal=a%2Bb%20c%25")
}

@Test func oauthLoginRejectsNonLoopbackRedirectURI() throws {
    let credential = testCredential(oauthClientSecretJSON: """
        {
          "installed": {
            "client_id": "client-id",
            "auth_uri": "https://accounts.example.test/o/oauth2/auth",
            "token_uri": "https://tokens.example.test/token"
          }
        }
        """)

    let error = try requireMailGatewayError {
        _ = try GmailOAuthBootstrapper().login(
            credential: credential,
            options: GmailOAuthLoginOptions(
                redirectURI: "https://example.com/oauth2callback",
                openBrowser: false,
                timeoutSeconds: 1
            )
        )
    }

    #expect(error.code == .authRequired)
    #expect(error.exitCode == .authenticationBootstrapError)
    #expect(error.message.contains("loopback"))
}

@Test func loopbackOAuthReceiverAcceptsLocalCallback() throws {
    let receiver = try LoopbackOAuthReceiver()
    let resultBox = OAuthCallbackResultBox()
    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInitiated).async {
        resultBox.result = Result {
            try receiver.waitForCode(expectedState: "state-value", timeoutSeconds: 5)
        }
        semaphore.signal()
    }

    let response = try sendRawHTTPRequest(to: receiver.redirectURI + "?state=state-value&code=auth-code")
    #expect(response.contains("HTTP/1.1 200 OK"))
    #expect(response.contains("Gmail authentication completed"))
    #expect(semaphore.wait(timeout: .now() + .seconds(5)) == .success)
    #expect(try resultBox.result?.get() == "auth-code")
}

@Test func loopbackOAuthReceiverPreservesLocalhostRedirectURI() throws {
    let port = try reserveFreeLoopbackPort()
    let receiver = try LoopbackOAuthReceiver(redirectURI: "http://localhost:\(port)/callback")

    #expect(receiver.redirectURI == "http://localhost:\(port)/callback")
}

@Test func base64URLDecoderRejectsStandardBase64Alphabet() throws {
    #expect(dataFromBase64URLString("-w") == Data([251]))
    #expect(dataFromBase64URLString("-w==") == Data([251]))
    #expect(dataFromBase64URLString("+w==") == nil)
    #expect(dataFromBase64URLString("abc=d") == nil)
    #expect(dataFromBase64URLString("a") == nil)
}

@Test func intValueRejectsBooleansAndNonIntegralNumbers() {
    #expect(intValue(42) == 42)
    #expect(intValue(NSNumber(value: 1)) == 1)
    #expect(intValue(" 42 ") == 42)
    #expect(intValue(true) == nil)
    #expect(intValue(NSNumber(value: true)) == nil)
    #expect(intValue(NSNumber(value: 1.25)) == nil)
}

@Test func accountCachePruneRejectsUnknownAccountWithoutForceUnwrap() throws {
    try withReaderService { service, _ in
        let error = try requireMailGatewayError {
            _ = try service.pruneCache(accountId: "missing", all: false)
        }

        #expect(error.code == .accountNotFound)
        #expect(error.exitCode == .graphqlExecutionError)
    }
}

@Test func accountCachePruneRequiresSelector() throws {
    try withReaderService { service, paths in
        let error = try requireMailGatewayError {
            _ = try service.pruneCache(accountId: nil, all: false)
        }

        #expect(error.code == .invalidArgument)
        #expect(error.exitCode == .invalidCliUsage)
        #expect(!FileManager.default.fileExists(atPath: paths.attachmentDir))
    }
}

@Test func outboundMailRejectsHeaderLineBreaksBeforeProviderCall() throws {
    try withWriteService { service in
        let input = OutboundMailInput(
            accountId: "personal",
            to: ["recipient@example.com"],
            subject: "Hello\nInjected: header",
            textBody: "Body"
        )

        let error = try requireMailGatewayError {
            _ = try service.sendMessage(input: input, mode: .directSend)
        }

        #expect(error.code == .invalidArgument)
        #expect(error.message.contains("line breaks"))
    }
}

@Test func outboundMailRejectsBlankRecipientsBeforeProviderCall() throws {
    try withWriteService { service in
        let input = OutboundMailInput(
            accountId: "personal",
            to: ["   "],
            subject: "Hello",
            textBody: "Body"
        )

        let error = try requireMailGatewayError {
            _ = try service.sendMessage(input: input, mode: .directSend)
        }

        #expect(error.code == .invalidArgument)
        #expect(error.message.contains("recipient values"))
    }
}

@Test func outboundMailRejectsConfiguredSenderLineBreaksBeforeProviderCall() throws {
    try withWriteService(emailAddress: "person@example.com\nInjected: header") { service in
        let input = OutboundMailInput(
            accountId: "personal",
            to: ["recipient@example.com"],
            subject: "Hello",
            textBody: "Body"
        )

        let error = try requireMailGatewayError {
            _ = try service.sendMessage(input: input, mode: .directSend)
        }

        #expect(error.code == .invalidArgument)
        #expect(error.message.contains("line breaks"))
    }
}

private func withReaderService(_ operation: (MailGatewayReaderService, TestConfigPaths) throws -> Void) throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }
    try operation(MailGatewayReaderService(config: testConfig(paths: paths)), paths)
}

private func withWriteService(
    accessMode: AccessMode = .readSend,
    emailAddress: String = "person@example.com",
    _ operation: (MailGatewayWriteService) throws -> Void
) throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }
    let config = testConfig(paths: paths, accessMode: accessMode, emailAddress: emailAddress)
    try operation(MailGatewayWriteService(config: config))
}

private struct TestConfigPaths {
    let root: String
    let cacheDir: String
    let attachmentDir: String
    let sendDir: String
}

private func temporaryConfigPaths() -> TestConfigPaths {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mail-gateway-tests-\(UUID().uuidString)", isDirectory: true)
    return TestConfigPaths(
        root: root.path,
        cacheDir: root.appendingPathComponent("cache", isDirectory: true).path,
        attachmentDir: root.appendingPathComponent("attachments", isDirectory: true).path,
        sendDir: root.appendingPathComponent("send", isDirectory: true).path
    )
}

private func testConfig(
    paths: TestConfigPaths,
    accessMode: AccessMode = .read,
    emailAddress: String = "person@example.com"
) -> MailGatewayConfig {
    MailGatewayConfig(
        configPath: paths.root + "/config.toml",
        storage: StorageConfig(
            cacheDir: paths.cacheDir,
            attachmentDir: paths.attachmentDir,
            allowedSendAttachmentRoots: [paths.sendDir]
        ),
        credentials: [
            CredentialConfig(
                id: "gmail-personal",
                provider: .gmail,
                accessMode: accessMode,
                oauthClientSecretPath: paths.root + "/client.json",
                oauthClientSecretJSON: nil,
                tokenStorePath: paths.root + "/token.json",
                tokenStoreJSON: nil
            )
        ],
        accounts: [
            AccountConfig(
                id: "personal",
                provider: .gmail,
                emailAddress: emailAddress,
                credentialId: "gmail-personal",
                defaultLabelIds: ["INBOX"]
            )
        ]
    )
}

private func testCredential(oauthClientSecretJSON: String, accessMode: AccessMode = .readSend) -> CredentialConfig {
    CredentialConfig(
        id: "gmail-personal",
        provider: .gmail,
        accessMode: accessMode,
        oauthClientSecretPath: "/tmp/client.json",
        oauthClientSecretJSON: oauthClientSecretJSON,
        tokenStorePath: "/tmp/token.json",
        tokenStoreJSON: nil
    )
}

private final class OAuthCallbackResultBox: @unchecked Sendable {
    var result: Result<String, Error>?
}

private func sendRawHTTPRequest(to urlString: String) throws -> String {
    guard let components = URLComponents(string: urlString),
          let host = components.host,
          let port = components.port else {
        throw ExpectedMailGatewayError(description: "Invalid callback URL: \(urlString)")
    }
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
        throw ExpectedMailGatewayError(description: "Failed to create callback test socket")
    }
    defer {
        close(socketFD)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr(host))
    let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.connect(socketFD, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else {
        throw ExpectedMailGatewayError(description: "Failed to connect to callback test server")
    }

    var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    if let query = components.percentEncodedQuery {
        target += "?\(query)"
    }
    let request = """
    GET \(target) HTTP/1.1\r
    Host: \(host):\(port)\r
    Connection: close\r
    \r

    """
    _ = request.withCString { pointer in
        Darwin.write(socketFD, pointer, strlen(pointer))
    }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
        let count = Darwin.read(socketFD, &buffer, buffer.count)
        if count <= 0 {
            break
        }
        response.append(contentsOf: buffer.prefix(Int(count)))
    }
    return String(data: response, encoding: .utf8) ?? ""
}

private func reserveFreeLoopbackPort() throws -> UInt16 {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
        throw ExpectedMailGatewayError(description: "Failed to create port reservation socket")
    }
    defer {
        close(socketFD)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.bind(socketFD, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        throw ExpectedMailGatewayError(description: "Failed to bind port reservation socket")
    }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            getsockname(socketFD, socketAddress, &length)
        }
    }
    guard nameResult == 0 else {
        throw ExpectedMailGatewayError(description: "Failed to read reserved loopback port")
    }
    return UInt16(bigEndian: boundAddress.sin_port)
}

private struct ExpectedMailGatewayError: Error, CustomStringConvertible {
    let description: String
}

private func requireMailGatewayError(_ operation: () throws -> Void) throws -> MailGatewayError {
    do {
        try operation()
        throw ExpectedMailGatewayError(description: "Expected MailGatewayError, but operation succeeded")
    } catch let error as MailGatewayError {
        return error
    } catch {
        throw ExpectedMailGatewayError(description: "Expected MailGatewayError, got \(error)")
    }
}
