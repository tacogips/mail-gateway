import Foundation

func executeReaderGraphQL(
    config: MailGatewayConfig,
    query: String
) throws -> (body: [String: Any], exitCode: MailGatewayExitCode) {
    let service = MailGatewayReaderService(config: config)
    do {
        return (["data": try executeReaderGraphQLData(service: service, query: query)], .success)
    } catch let error as MailGatewayError where error.exitCode == .graphqlExecutionError {
        let extensions: [String: Any] = [
            "code": error.code.rawValue,
            "exitCode": error.exitCode.rawValue
        ]
        let errors: [[String: Any]] = [[
            "message": error.message,
            "extensions": extensions
        ]]
        let body: [String: Any] = [
            "data": NSNull(),
            "errors": errors
        ]
        return (body, .graphqlExecutionError)
    }
}

private func executeReaderGraphQLData(service: MailGatewayReaderService, query: String) throws -> [String: Any] {
    if rootFieldSource("accounts", in: query) != nil {
        return ["accounts": service.graphQLAccounts()]
    }
    if let source = rootFieldSource("account", in: query) {
        return [
            "account": service.graphQLAccount(id: try extractStringArgument("id", from: source)) as Any? ?? NSNull()
        ]
    }
    if let source = rootFieldSource("threads", in: query) {
        let selection = selectionBody(for: "threads", in: source, atBraceDepth: 0) ?? ""
        let edgeSelection = selectionBody(for: "edges", in: selection, atBraceDepth: 0) ?? ""
        return [
            "threads": projectThreadConnectionSelection(
                try service.searchThreads(
                    accountId: try extractStringArgument("accountId", from: source),
                    query: try extractOptionalStringArgument("query", from: source),
                    includeEdges: directFieldExists("edges", in: selection),
                    includeNodeDetails: directFieldExists("node", in: edgeSelection)
                ),
                selection: selection
            )
        ]
    }
    if let source = rootFieldSource("thread", in: query) {
        return try graphQLThreadData(service: service, query: source)
    }
    if let source = rootFieldSource("messageFileSet", in: query) {
        return try graphQLMessageFileSetData(service: service, query: source)
    }
    if let source = rootFieldSource("message", in: query) {
        return try graphQLMessageData(service: service, query: source)
    }
    if let source = rootFieldSource("attachment", in: query) {
        return try graphQLAttachmentData(service: service, query: source)
    }
    throw MailGatewayError(
        "Unsupported GraphQL query",
        code: .invalidArgument,
        exitCode: .graphqlExecutionError
    )
}

private func projectThreadConnectionSelection(_ connection: [String: Any], selection: String) -> [String: Any] {
    var object: [String: Any] = [:]
    if directFieldExists("totalCount", in: selection),
       let totalCount = connection["totalCount"] {
        object["totalCount"] = totalCount
    }
    if directFieldExists("pageInfo", in: selection),
       let pageInfo = connection["pageInfo"] {
        object["pageInfo"] = pageInfo
    }
    if directFieldExists("edges", in: selection),
       let edges = connection["edges"] {
        object["edges"] = projectThreadEdgesSelection(
            edges,
            selection: selectionBody(for: "edges", in: selection, atBraceDepth: 0) ?? ""
        )
    }
    return object
}

private func projectThreadEdgesSelection(_ edges: Any, selection: String) -> Any {
    guard let edgeObjects = edges as? [[String: Any]] else {
        return edges
    }
    guard !directFieldExists("node", in: selection) else {
        return edgeObjects
    }
    return edgeObjects.map { edge in
        var projected: [String: Any] = [:]
        if directFieldExists("cursor", in: selection),
           let cursor = edge["cursor"] {
            projected["cursor"] = cursor
        }
        return projected
    }
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
    let selection = selectionBody(for: "attachment", in: query, atBraceDepth: 0) ?? ""
    return [
        "attachment": projectAttachmentSelection(
            try service.getAttachment(
                accountId: extractStringArgument("accountId", from: query),
                messageId: extractStringArgument("messageId", from: query),
                attachmentId: extractStringArgument("attachmentId", from: query)
            ),
            selection: selection
        )
    ]
}

private func projectAttachmentSelection(_ attachment: Any, selection: String) -> Any {
    guard var object = attachment as? [String: Any] else {
        return attachment
    }
    for field in object.keys where !directFieldExists(field, in: selection) {
        object.removeValue(forKey: field)
    }
    return object
}

private func rootFieldSource(_ field: String, in query: String) -> String? {
    fieldSource(for: field, in: query, atBraceDepth: 1)
}

private func fieldSource(for field: String, in query: String, atBraceDepth braceDepth: Int) -> String? {
    guard let range = rangeOfField(field, in: query, atBraceDepth: braceDepth) else {
        return nil
    }
    var index = skipWhitespace(in: query, from: range.upperBound)
    if index < query.endIndex,
       query[index] == "(",
       let endIndex = indexAfterBalancedDelimiter(in: query, from: index, open: "(", close: ")") {
        index = skipWhitespace(in: query, from: endIndex)
    }
    if index < query.endIndex,
       query[index] == "{",
       let endIndex = indexAfterBalancedDelimiter(in: query, from: index, open: "{", close: "}") {
        return String(query[range.lowerBound..<endIndex])
    }
    return String(query[range.lowerBound..<index])
}

private func selectionBody(for field: String, in query: String, atBraceDepth braceDepth: Int) -> String? {
    guard let range = rangeOfField(field, in: query, atBraceDepth: braceDepth) else {
        return nil
    }
    var index = skipWhitespace(in: query, from: range.upperBound)
    if index < query.endIndex,
       query[index] == "(",
       let endIndex = indexAfterBalancedDelimiter(in: query, from: index, open: "(", close: ")") {
        index = skipWhitespace(in: query, from: endIndex)
    }
    guard index < query.endIndex,
          query[index] == "{",
          let endIndex = indexAfterBalancedDelimiter(in: query, from: index, open: "{", close: "}") else {
        return nil
    }
    return String(query[query.index(after: index)..<query.index(before: endIndex)])
}

private func directFieldExists(_ field: String, in selection: String) -> Bool {
    rangeOfField(field, in: selection, atBraceDepth: 0) != nil
}

private func rangeOfField(_ field: String, in query: String, atBraceDepth requiredBraceDepth: Int?) -> Range<String.Index>? {
    var index = query.startIndex
    var inString = false
    var escaping = false
    var braceDepth = 0
    var parenDepth = 0
    while index < query.endIndex {
        let character = query[index]
        if inString {
            if escaping {
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "\"" {
                inString = false
            }
            index = query.index(after: index)
            continue
        }
        if character == "\"" {
            inString = true
            index = query.index(after: index)
            continue
        }
        if character == "{" {
            braceDepth += 1
            index = query.index(after: index)
            continue
        }
        if character == "}" {
            braceDepth = max(0, braceDepth - 1)
            index = query.index(after: index)
            continue
        }
        if character == "(" {
            parenDepth += 1
            index = query.index(after: index)
            continue
        }
        if character == ")" {
            parenDepth = max(0, parenDepth - 1)
            index = query.index(after: index)
            continue
        }
        if query[index...].hasPrefix(field) {
            let endIndex = query.index(index, offsetBy: field.count)
            let before = index > query.startIndex ? query[query.index(before: index)] : " "
            let after = endIndex < query.endIndex ? query[endIndex] : " "
            let braceDepthMatches = requiredBraceDepth.map { $0 == braceDepth } ?? true
            if braceDepthMatches && parenDepth == 0 && !isGraphQLIdentifier(before) && !isGraphQLIdentifier(after) {
                return index..<endIndex
            }
        }
        index = query.index(after: index)
    }
    return nil
}

private func skipWhitespace(in query: String, from startIndex: String.Index) -> String.Index {
    var index = startIndex
    while index < query.endIndex,
          query[index].isWhitespace {
        index = query.index(after: index)
    }
    return index
}

private func indexAfterBalancedDelimiter(
    in query: String,
    from openIndex: String.Index,
    open: Character,
    close: Character
) -> String.Index? {
    var index = openIndex
    var depth = 0
    var inString = false
    var escaping = false
    while index < query.endIndex {
        let character = query[index]
        if inString {
            if escaping {
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "\"" {
                inString = false
            }
            index = query.index(after: index)
            continue
        }
        if character == "\"" {
            inString = true
            index = query.index(after: index)
            continue
        }
        if character == open {
            depth += 1
        } else if character == close {
            depth -= 1
            if depth == 0 {
                return query.index(after: index)
            }
        }
        index = query.index(after: index)
    }
    return nil
}

private func isGraphQLIdentifier(_ character: Character) -> Bool {
    character == "_" || character.isLetter || character.isNumber
}

private func extractStringArgument(_ name: String, from query: String) throws -> String {
    guard let range = rangeOfArgumentLabel(name, in: query) else {
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

private func extractOptionalStringArgument(_ name: String, from query: String) throws -> String? {
    guard let range = rangeOfArgumentLabel(name, in: query) else {
        return nil
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

private func rangeOfArgumentLabel(_ name: String, in query: String) -> Range<String.Index>? {
    var index = query.startIndex
    var inString = false
    var escaping = false
    var parenDepth = 0
    while index < query.endIndex {
        let character = query[index]
        if inString {
            if escaping {
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "\"" {
                inString = false
            }
            index = query.index(after: index)
            continue
        }
        if character == "\"" {
            inString = true
            index = query.index(after: index)
            continue
        }
        if character == "(" {
            parenDepth += 1
            index = query.index(after: index)
            continue
        }
        if character == ")" {
            parenDepth = max(0, parenDepth - 1)
            index = query.index(after: index)
            continue
        }
        if query[index...].hasPrefix(name) {
            let nameEndIndex = query.index(index, offsetBy: name.count)
            let before = index > query.startIndex ? query[query.index(before: index)] : " "
            let after = nameEndIndex < query.endIndex ? query[nameEndIndex] : " "
            if parenDepth > 0 && !isGraphQLIdentifier(before) && !isGraphQLIdentifier(after) {
                var labelEndIndex = nameEndIndex
                while labelEndIndex < query.endIndex,
                      query[labelEndIndex].isWhitespace {
                    labelEndIndex = query.index(after: labelEndIndex)
                }
                if labelEndIndex < query.endIndex,
                   query[labelEndIndex] == ":" {
                    return index..<query.index(after: labelEndIndex)
                }
            }
        }
        index = query.index(after: index)
    }
    return nil
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
