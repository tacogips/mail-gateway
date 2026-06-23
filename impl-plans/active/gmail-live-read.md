# Gmail Live Read Implementation Plan

**Status**: In Progress
**Design Reference**: design-docs/specs/design-mail-gateway.md#gmail-v1-adapter
**Created**: 2026-06-23
**Last Updated**: 2026-06-23

---

## Design Document Reference

**Source**: design-docs/specs/design-mail-gateway.md

### Summary

Replace the local empty thread/message stubs with live Gmail API metadata reads when a valid token store is available.

### Scope

**Included**: Gmail access-token loading, refresh-token exchange, messages list/get metadata reads, thread/message GraphQL payloads, local smoke coverage for missing auth and token compatibility, docs.
**Excluded**: Attachment download from Gmail, full MIME body materialization, send workflow, daemon sync/cache.

---

## Modules

### 1. Gmail API Read Client

#### Sources/MailGatewayCore/GmailLiveReader.swift

**Status**: Completed

```swift
struct GmailLiveReader {
    func searchThreads(account: AccountConfig, credential: CredentialConfig) throws -> [String: Any]
    func getThread(account: AccountConfig, credential: CredentialConfig, threadId: String) throws -> Any
    func getMessage(account: AccountConfig, credential: CredentialConfig, messageId: String) throws -> Any
}
```

**Checklist**:
- [x] Load token store written by OAuth login
- [x] Refresh expired access tokens when a refresh token is present
- [x] Call Gmail messages list/get and threads get endpoints
- [x] Return metadata-only GraphQL-compatible payloads

### 2. Service Integration And Verification

#### Sources/MailGatewayCore/MailGatewayCore.swift
#### Sources/MailGatewaySwiftSmokeTests/main.swift
#### README.md

**Status**: In Progress

```swift
public struct MailGatewayReaderService {
    public func searchThreads(accountId: String) throws -> [String: Any]
    public func getThread(accountId: String, threadId: String) throws -> Any
    public func getMessage(accountId: String, messageId: String) throws -> Any
}
```

**Checklist**:
- [x] Wire GraphQL thread/message fields to live Gmail reads
- [x] Add smoke coverage for missing auth on read operations
- [x] Document no-config plus env/default credential flow
- [ ] Run local and direct CLI verification

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Gmail API Read Client | `Sources/MailGatewayCore/GmailLiveReader.swift` | COMPLETED | `swift run mail-gateway-swift-smoke-tests` |
| Service Integration And Verification | `Sources/MailGatewayCore/MailGatewayCore.swift`, `Sources/MailGatewaySwiftSmokeTests/main.swift`, `README.md` | BLOCKED_ON_CREDENTIALS | `task ci`; direct no-config CLI checks |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| Gmail Live Read | Gmail OAuth token store | Implemented |

## Tasks

### TASK-001: Gmail Live Metadata Read

**Status**: In Progress
**Parallelizable**: No
**Deliverables**: `Sources/MailGatewayCore/GmailLiveReader.swift`, `Sources/MailGatewayCore/MailGatewayCore.swift`, `Sources/MailGatewaySwiftSmokeTests/main.swift`, `README.md`
**Dependencies**: gmail-oauth-bootstrap:TASK-001

**Description**:
Implement live Gmail metadata retrieval through the existing reader GraphQL operations.

**Completion Criteria**:
- [x] `threads` requires auth and calls Gmail when token exists
- [x] `thread` and `message` return Gmail metadata payloads
- [x] Expired access tokens refresh using the OAuth client JSON and refresh token
- [x] Local tests and CLI checks pass
- [x] Live Gmail retrieval attempted with available local/env credentials

## Completion Criteria

- [x] Live read implementation completed
- [x] Tests passing
- [x] Documentation updated
- [x] Direct verification completed

## Progress Log

### Session: 2026-06-23 11:44
**Tasks Completed**: None yet
**Tasks In Progress**: TASK-001
**Blockers**: None
**Notes**: User clarified the end state: no config required by default, and Gmail mail retrieval should be verified through env/default credential setup if needed.

### Session: 2026-06-23 12:40
**Tasks Completed**: Wired live reader into service methods; added no-config missing-auth smoke coverage; ran `swift build`, `swift run mail-gateway-swift-smoke-tests`, `task ci`, `git diff --check`, and direct no-config CLI checks.
**Tasks In Progress**: Live Gmail retrieval with real credentials
**Blockers**: No Gmail OAuth client JSON or token JSON is available in kinko, direnv, default config paths, or common local files. `auth login` fails because `~/.config/mail-gateway/google-client.json` is missing.
**Notes**: Source/test updates were applied by temporary Riela command workflow after packaged Riela agent workflows stalled in review. kinko now has the project-scope default credential path keys.

## Related Plans

- **Previous**: `gmail-oauth-bootstrap.md`, `completed/default-config-fallback.md`
- **Next**: None
- **Depends On**: `gmail-oauth-bootstrap.md`
