# Command Design

This document describes CLI command interface design specifications.

## Overview

Command-line interface design decisions, including subcommands, flags, options, and environment variables.

## Mail Gateway Command Surface

Detailed specification: [design-mail-gateway.md](./design-mail-gateway.md)

### Binaries

| Binary | Purpose |
|--------|---------|
| `mail-gateway-reader` | Phase 1 binary. Execute GraphQL read operations only |
| `mail-gateway` | Future Phase 2 binary. Execute GraphQL read and send operations |

### Subcommands

| Command | Applies To | Purpose |
|---------|------------|---------|
| `graphql` | `mail-gateway-reader` in Phase 1 | Execute a GraphQL document with optional variables |
| `auth status` | `mail-gateway-reader` in Phase 1 | Report token presence, validity hints, and access-mode mismatch for a credential profile |
| `auth login` | `mail-gateway-reader` in Phase 1 | Perform OAuth bootstrap for a credential profile |
| `auth revoke` | `mail-gateway-reader` in Phase 1 | Remove or invalidate locally stored tokens for a credential profile |
| `config validate` | `mail-gateway-reader` in Phase 1 | Validate config structure, provider bindings, and path availability |
| `cache prune` | `mail-gateway-reader` in Phase 1 | Remove materialized attachments from the local cache |
| `serve` | Later phase only | Expose the same schema over a local HTTP listener |

### Flags and Options

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--config` | path | XDG default | Path to `config.toml` |
| `--query` | string | none | Inline GraphQL document |
| `--query-file` | path | none | GraphQL document file |
| `--variables` | JSON string | `{}` | Inline variables payload |
| `--variables-file` | path | none | Variables JSON file |
| `--listen` | host:port | none | Listener for `serve` mode |
| `--credential` | ID | none | Credential profile for `auth` operations |
| `--account` | ID | none | Account scope for `cache prune` |
| `--all` | boolean | `false` | Prune all materialized attachments |
| `--pretty` | boolean | `false` | Pretty-print GraphQL JSON output |

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MAIL_GATEWAY_CONFIG` | No | XDG default | Config file override |
| `MAIL_GATEWAY_LOG` | No | `info` | Log level |
| `MAIL_GATEWAY_REQUEST_TIMEOUT_MS` | No | provider default | API request timeout override |

Credential path overrides are also supported per credential ID:

- `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_OAUTH_CLIENT_SECRET_PATH`
- `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_TOKEN_STORE_PATH`

`<CREDENTIAL_ID>` is derived from `credentials[].id` by uppercasing it and replacing non-alphanumeric characters with `_`. These env vars override TOML when both are present.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Invalid CLI usage |
| 3 | Configuration error |
| 4 | Authentication bootstrap error |
| 5 | GraphQL execution error |
| 6 | Provider API error |

### Phase 1 Notes

- `mail-gateway-reader` is the only binary required in the initial release
- `serve` is intentionally deferred
- `auth login` must request scopes that match the configured credential `access_mode`
- attachments are exchanged only as files via `attachment(...)` and `localPath`, not inline payloads

---
