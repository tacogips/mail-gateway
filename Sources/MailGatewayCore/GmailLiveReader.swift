import Foundation

struct GmailLiveReader {
    func searchThreads(account: AccountConfig, credential: CredentialConfig) throws -> [String: Any] {
        let accessToken = try validAccessToken(credential: credential)
        let listed = try listMessages(account: account, accessToken: accessToken)
        var seenThreads: Set<String> = []
        var edges: [[String: Any]] = []

        for item in listed.messages {
            guard !seenThreads.contains(item.threadId) else {
                continue
            }
            seenThreads.insert(item.threadId)
            let message = try getMessageMetadata(messageId: item.id, account: account, accessToken: accessToken)
            let thread = buildThread(account: account, threadId: item.threadId, messages: [message])
            edges.append([
                "cursor": item.id,
                "node": thread
            ])
        }

        return [
            "edges": edges,
            "pageInfo": [
                "hasNextPage": listed.nextPageToken != nil,
                "endCursor": listed.nextPageToken as Any? ?? NSNull()
            ],
            "totalCount": listed.resultSizeEstimate ?? edges.count
        ]
    }

    func getThread(account: AccountConfig, credential: CredentialConfig, threadId: String) throws -> Any {
        let accessToken = try validAccessToken(credential: credential)
        var components = gmailURLComponents(path: "/gmail/v1/users/me/threads/\(urlPathEncode(threadId))")
        components.queryItems = metadataQueryItems()
        let object = try getGmailJSONObject(
            components: components,
            accessToken: accessToken,
            context: "Gmail thread metadata retrieval failed"
        )
        let messages = (object["messages"] as? [[String: Any]] ?? [])
            .map { buildMessage(account: account, object: $0) }
        return buildThread(account: account, threadId: threadId, messages: messages)
    }

    func getMessage(account: AccountConfig, credential: CredentialConfig, messageId: String) throws -> Any {
        let accessToken = try validAccessToken(credential: credential)
        return try getMessageMetadata(messageId: messageId, account: account, accessToken: accessToken)
    }
}

private struct GmailListedMessages {
    let messages: [GmailListedMessage]
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

private struct GmailListedMessage {
    let id: String
    let threadId: String
}

private struct GmailOAuthClientForRefresh: Decodable {
    let clientId: String
    let clientSecret: String?
    let tokenURI: String

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
        case tokenURI = "token_uri"
    }
}

private struct GmailOAuthClientFileForRefresh: Decodable {
    let installed: GmailOAuthClientForRefresh?
}

private func validAccessToken(credential: CredentialConfig) throws -> String {
    let tokenStore = try loadTokenStore(credential: credential)
    if let expiresAt = tokenStore.expiresAt,
       let expiresAtDate = ISO8601DateFormatter().date(from: expiresAt),
       expiresAtDate <= Date().addingTimeInterval(60) {
        return try refreshAccessToken(credential: credential, tokenStore: tokenStore)
    }
    return tokenStore.accessToken
}

private func loadTokenStore(credential: CredentialConfig) throws -> GmailOAuthTokenStore {
    do {
        let data: Data
        if let tokenStoreJSON = credential.tokenStoreJSON {
            data = Data(tokenStoreJSON.utf8)
        } else {
            guard FileManager.default.isReadableFile(atPath: credential.tokenStorePath) else {
                throw MailGatewayError(
                    "Authentication is required before reading Gmail",
                    code: .authRequired,
                    exitCode: .graphqlExecutionError,
                    details: ["credentialId": credential.id, "tokenStorePath": credential.tokenStorePath]
                )
            }
            data = try Data(contentsOf: URL(fileURLWithPath: credential.tokenStorePath))
        }
        let tokenStore = try JSONDecoder().decode(GmailOAuthTokenStore.self, from: data)
        guard tokenStore.accessMode == credential.accessMode else {
            throw MailGatewayError(
                "Stored Gmail token scope does not match configured access mode",
                code: .authRequired,
                exitCode: .graphqlExecutionError,
                details: ["credentialId": credential.id]
            )
        }
        return tokenStore
    } catch let error as MailGatewayError {
        throw error
    } catch {
        throw MailGatewayError(
            "Failed to read Gmail token store",
            code: .authRequired,
            exitCode: .graphqlExecutionError,
            details: ["credentialId": credential.id, "cause": error.localizedDescription]
        )
    }
}

private func refreshAccessToken(credential: CredentialConfig, tokenStore: GmailOAuthTokenStore) throws -> String {
    guard let refreshToken = nonBlank(tokenStore.refreshToken) else {
        throw MailGatewayError(
            "Stored Gmail access token is expired and has no refresh token",
            code: .authRequired,
            exitCode: .graphqlExecutionError,
            details: ["credentialId": credential.id]
        )
    }
    let client = try loadOAuthClientForRefresh(credential: credential)
    guard let tokenURL = URL(string: client.tokenURI) else {
        throw MailGatewayError(
            "OAuth client token_uri is invalid",
            code: .configInvalid,
            exitCode: .configurationError,
            details: ["credentialId": credential.id]
        )
    }

    var fields = [
        ("client_id", client.clientId),
        ("grant_type", "refresh_token"),
        ("refresh_token", refreshToken)
    ]
    if let clientSecret = nonBlank(client.clientSecret) {
        fields.append(("client_secret", clientSecret))
    }

    var request = URLRequest(url: tokenURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formURLEncoded(fields).data(using: .utf8)
    let response = try performGmailHTTPRequest(request, context: "Gmail token refresh failed")
    guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
          let accessToken = nonBlank(object["access_token"] as? String) else {
        throw MailGatewayError(
            "Gmail token refresh response did not include an access token",
            code: .authRequired,
            exitCode: .graphqlExecutionError,
            details: ["credentialId": credential.id]
        )
    }

    let refreshed = GmailOAuthTokenStore(
        accessMode: tokenStore.accessMode,
        accessToken: accessToken,
        refreshToken: tokenStore.refreshToken,
        tokenType: nonBlank(object["token_type"] as? String) ?? tokenStore.tokenType,
        scope: nonBlank(object["scope"] as? String) ?? tokenStore.scope,
        expiresAt: (object["expires_in"] as? Int).map {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval($0)))
        },
        emailAddress: tokenStore.emailAddress
    )
    try? writeRefreshedTokenStore(refreshed, to: credential.tokenStorePath)
    return accessToken
}

private func loadOAuthClientForRefresh(credential: CredentialConfig) throws -> GmailOAuthClientForRefresh {
    do {
        let data: Data
        if let oauthClientSecretJSON = credential.oauthClientSecretJSON {
            data = Data(oauthClientSecretJSON.utf8)
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: credential.oauthClientSecretPath))
        }
        let decoded = try JSONDecoder().decode(GmailOAuthClientFileForRefresh.self, from: data)
        guard let installed = decoded.installed else {
            throw MailGatewayError(
                "OAuth client JSON must contain an installed desktop client",
                code: .configInvalid,
                exitCode: .configurationError,
                details: ["credentialId": credential.id]
            )
        }
        return installed
    } catch let error as MailGatewayError {
        throw error
    } catch {
        throw MailGatewayError(
            "Failed to read Gmail OAuth client JSON",
            code: .configInvalid,
            exitCode: .configurationError,
            details: ["credentialId": credential.id, "cause": error.localizedDescription]
        )
    }
}

private func writeRefreshedTokenStore(_ tokenStore: GmailOAuthTokenStore, to path: String) throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let data = try JSONEncoder().encode(tokenStore)
    try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}

private func listMessages(account: AccountConfig, accessToken: String) throws -> GmailListedMessages {
    var components = gmailURLComponents(path: "/gmail/v1/users/me/messages")
    var queryItems = [
        URLQueryItem(name: "maxResults", value: "10")
    ]
    for labelId in account.defaultLabelIds {
        queryItems.append(URLQueryItem(name: "labelIds", value: labelId))
    }
    components.queryItems = queryItems
    let object = try getGmailJSONObject(
        components: components,
        accessToken: accessToken,
        context: "Gmail message list failed"
    )
    let messages = (object["messages"] as? [[String: Any]] ?? []).compactMap { item -> GmailListedMessage? in
        guard let id = nonBlank(item["id"] as? String),
              let threadId = nonBlank(item["threadId"] as? String) else {
            return nil
        }
        return GmailListedMessage(id: id, threadId: threadId)
    }
    return GmailListedMessages(
        messages: messages,
        nextPageToken: nonBlank(object["nextPageToken"] as? String),
        resultSizeEstimate: object["resultSizeEstimate"] as? Int
    )
}

private func getMessageMetadata(messageId: String, account: AccountConfig, accessToken: String) throws -> [String: Any] {
    var components = gmailURLComponents(path: "/gmail/v1/users/me/messages/\(urlPathEncode(messageId))")
    components.queryItems = metadataQueryItems()
    let object = try getGmailJSONObject(
        components: components,
        accessToken: accessToken,
        context: "Gmail message metadata retrieval failed"
    )
    return buildMessage(account: account, object: object)
}

private func getGmailJSONObject(
    components: URLComponents,
    accessToken: String,
    context: String
) throws -> [String: Any] {
    guard let url = components.url else {
        throw MailGatewayError(
            "Failed to construct Gmail API URL",
            code: .providerApiError,
            exitCode: .providerApiError
        )
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    let response = try performGmailHTTPRequest(request, context: context)
    guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
        throw MailGatewayError(
            "Gmail API response was not a JSON object",
            code: .providerApiError,
            exitCode: .providerApiError
        )
    }
    return object
}

private func performGmailHTTPRequest(_ request: URLRequest, context: String) throws -> (data: Data, response: HTTPURLResponse) {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<(Data, HTTPURLResponse), Error>?
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer {
            semaphore.signal()
        }
        if let error {
            result = .failure(error)
            return
        }
        guard let data,
              let httpResponse = response as? HTTPURLResponse else {
            result = .failure(MailGatewayError(
                "Gmail API response was empty",
                code: .providerApiError,
                exitCode: .providerApiError
            ))
            return
        }
        result = .success((data, httpResponse))
    }.resume()
    semaphore.wait()

    let resolved: (data: Data, response: HTTPURLResponse)
    do {
        resolved = try result?.get() ?? {
            throw MailGatewayError(
                "Gmail API request did not complete",
                code: .providerApiError,
                exitCode: .providerApiError
            )
        }()
    } catch let error as MailGatewayError {
        throw error
    } catch {
        throw MailGatewayError(
            context,
            code: .providerApiError,
            exitCode: .providerApiError,
            details: ["cause": error.localizedDescription]
        )
    }

    guard (200..<300).contains(resolved.response.statusCode) else {
        let body = String(data: resolved.data, encoding: .utf8) ?? ""
        throw MailGatewayError(
            context,
            code: .providerApiError,
            exitCode: .providerApiError,
            details: ["httpStatus": String(resolved.response.statusCode), "body": String(body.prefix(1_000))]
        )
    }
    return resolved
}

private func buildThread(account: AccountConfig, threadId: String, messages: [[String: Any]]) -> [String: Any] {
    let labels = uniqueStrings(messages.flatMap { $0["labels"] as? [String] ?? [] })
    return [
        "id": threadId,
        "accountId": account.id,
        "subject": messages.first?["subject"] as? String ?? NSNull(),
        "snippet": messages.first?["snippet"] as? String ?? NSNull(),
        "messages": messages,
        "labels": labels,
        "providerMetadata": [
            "gmail": [
                "labelIds": labels,
                "historyId": messages.first?["historyId"] as? String ?? NSNull()
            ] as [String: Any]
        ]
    ]
}

private func buildMessage(account: AccountConfig, object: [String: Any]) -> [String: Any] {
    let headers = gmailHeaders(object)
    let labelIds = object["labelIds"] as? [String] ?? []
    let internalDate = nonBlank(object["internalDate"] as? String).flatMap(millisecondsDateString)
    return [
        "id": object["id"] as? String ?? "",
        "threadId": object["threadId"] as? String ?? "",
        "accountId": account.id,
        "subject": headers["subject"] ?? NSNull(),
        "from": mailAddressList(headers["from"]),
        "to": mailAddressList(headers["to"]),
        "cc": mailAddressList(headers["cc"]),
        "bcc": mailAddressList(headers["bcc"]),
        "replyTo": mailAddressList(headers["reply-to"]),
        "sentAt": parseMailDate(headers["date"]) as Any? ?? internalDate as Any? ?? NSNull(),
        "receivedAt": internalDate as Any? ?? NSNull(),
        "snippet": object["snippet"] as? String ?? NSNull(),
        "textBody": NSNull(),
        "htmlBody": NSNull(),
        "attachments": [[String: Any]](),
        "labels": labelIds,
        "historyId": object["historyId"] as? String ?? NSNull(),
        "providerMetadata": [
            "gmail": [
                "labelIds": labelIds,
                "historyId": object["historyId"] as? String ?? NSNull()
            ] as [String: Any]
        ]
    ]
}

private func gmailHeaders(_ object: [String: Any]) -> [String: String] {
    guard let payload = object["payload"] as? [String: Any],
          let headers = payload["headers"] as? [[String: Any]] else {
        return [:]
    }
    var output: [String: String] = [:]
    for header in headers {
        guard let name = nonBlank(header["name"] as? String),
              let value = nonBlank(header["value"] as? String) else {
            continue
        }
        output[name.lowercased()] = value
    }
    return output
}

private func mailAddressList(_ value: String?) -> [[String: String]] {
    guard let value = nonBlank(value) else {
        return []
    }
    return value.split(separator: ",").map {
        ["raw": $0.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}

private func parseMailDate(_ value: String?) -> String? {
    guard let value = nonBlank(value) else {
        return nil
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
    if let date = formatter.date(from: value) {
        return ISO8601DateFormatter().string(from: date)
    }
    return value
}

private func millisecondsDateString(_ value: String) -> String? {
    guard let milliseconds = Double(value) else {
        return nil
    }
    return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: milliseconds / 1_000))
}

private func metadataQueryItems() -> [URLQueryItem] {
    [
        URLQueryItem(name: "format", value: "metadata"),
        URLQueryItem(name: "metadataHeaders", value: "Subject"),
        URLQueryItem(name: "metadataHeaders", value: "From"),
        URLQueryItem(name: "metadataHeaders", value: "To"),
        URLQueryItem(name: "metadataHeaders", value: "Cc"),
        URLQueryItem(name: "metadataHeaders", value: "Bcc"),
        URLQueryItem(name: "metadataHeaders", value: "Reply-To"),
        URLQueryItem(name: "metadataHeaders", value: "Date")
    ]
}

private func gmailURLComponents(path: String) -> URLComponents {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "gmail.googleapis.com"
    components.path = path
    return components
}

private func formURLEncoded(_ fields: [(String, String)]) -> String {
    fields
        .map { key, value in
            "\(urlFormEncode(key))=\(urlFormEncode(value))"
        }
        .joined(separator: "&")
}

private func urlPathEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
}

private func urlFormEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func uniqueStrings(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var output: [String] = []
    for value in values where !seen.contains(value) {
        seen.insert(value)
        output.append(value)
    }
    return output
}
