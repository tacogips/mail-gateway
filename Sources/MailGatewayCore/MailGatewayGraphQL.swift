import Foundation

func executeReaderGraphQL(
    config: MailGatewayConfig,
    query: String
) throws -> (body: [String: Any], exitCode: MailGatewayExitCode) {
    let service = MailGatewayReaderService(config: config)
    do {
        return (["data": try executeReaderGraphQLData(service: service, query: query)], .success)
    } catch let error as MailGatewayError where error.exitCode == .graphqlExecutionError {
        return ([
            "data": NSNull(),
            "errors": [[
                "message": error.message,
                "extensions": [
                    "code": error.code.rawValue,
                    "exitCode": error.exitCode.rawValue
                ]
            ]]
        ], .graphqlExecutionError)
    }
}

private func executeReaderGraphQLData(service: MailGatewayReaderService, query: String) throws -> [String: Any] {
    if fieldExists("accounts", in: query) {
        return ["accounts": service.graphQLAccounts()]
    }
    if fieldExists("account", in: query) {
        return [
            "account": service.graphQLAccount(id: try extractStringArgument("id", from: query)) as Any? ?? NSNull()
        ]
    }
    if fieldExists("threads", in: query) {
        return ["threads": try service.searchThreads(accountId: try extractStringArgument("accountId", from: query))]
    }
    if fieldExists("thread", in: query) {
        return try graphQLThreadData(service: service, query: query)
    }
    if fieldExists("messageFileSet", in: query) {
        return try graphQLMessageFileSetData(service: service, query: query)
    }
    if fieldExists("message", in: query) {
        return try graphQLMessageData(service: service, query: query)
    }
    if fieldExists("attachment", in: query) {
        return try graphQLAttachmentData(service: service, query: query)
    }
    throw MailGatewayError(
        "Unsupported GraphQL query",
        code: .invalidArgument,
        exitCode: .graphqlExecutionError
    )
}

private func graphQLThreadData(service: MailGatewayReaderService, query: String) throws -> [String: Any] {
    [
        "thread": try service.getThread(
            accountId: try extractStringArgument("accountId", from: query),
            threadId: try extractStringArgument("threadId", from: query)
        )
    ]
}

private func graphQLMessageFileSetData(service: MailGatewayReaderService, query: String) throws -> [String: Any] {
    [
        "messageFileSet": try service.getMessageFileSet(
            accountId: try extractStringArgument("accountId", from: query),
            messageId: try extractStringArgument("messageId", from: query)
        )
    ]
}

private func graphQLMessageData(service: MailGatewayReaderService, query: String) throws -> [String: Any] {
    [
        "message": try service.getMessage(
            accountId: try extractStringArgument("accountId", from: query),
            messageId: try extractStringArgument("messageId", from: query)
        )
    ]
}

private func graphQLAttachmentData(service: MailGatewayReaderService, query: String) throws -> [String: Any] {
    [
        "attachment": projectAttachmentSelection(
            try service.getAttachment(
                accountId: extractStringArgument("accountId", from: query),
                messageId: extractStringArgument("messageId", from: query),
                attachmentId: extractStringArgument("attachmentId", from: query)
            ),
            query: query
        )
    ]
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
    return try readGraphQLStringArgument(name: name, query: query, index: query.index(after: index))
}

private func readGraphQLStringArgument(name: String, query: String, index: String.Index) throws -> String {
    var index = index
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
