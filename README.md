# mail-gateway

AI-oriented local mail gateway implemented as a Swift package.

The package exposes:

- `MailGatewayCore`: Swift library for config loading, reader service behavior, and CLI execution
- `mail-gateway-reader`: Phase 1 read-only command surface
- `mail-gateway-draft`: default write surface where `sendMessage` creates a mail draft
- `mail-gateway-sender`: explicit direct-send surface where `sendMessage` sends mail
- `mail-gateway-swift-smoke-tests`: executable verification harness

## Build

```bash
swift build -c release
```

```bash
task install PREFIX="$HOME/.local"
```

## Commands

`mail-gateway-reader` supports the Phase 1 local reader surface:

```bash
mail-gateway-reader config validate --config ./config.toml --pretty
mail-gateway-reader auth status --config ./config.toml --credential gmail-personal
mail-gateway-reader auth revoke --config ./config.toml --credential gmail-personal
mail-gateway-reader cache prune --config ./config.toml --account personal
mail-gateway-reader graphql --config ./config.toml --query '{ accounts { id emailAddress } }'
mail-gateway-reader graphql --config ./config.toml \
  --query '{ threads(input: { accountId: "personal", query: "kakaku.com", direction: SENT, receivedAfter: "2026-06-25", receivedBefore: "2026-06-26" }) { totalCount } }'
mail-gateway-reader file download --config ./config.toml --key <download-key> --output-dir ./downloads
mail-gateway-reader file download --config ./config.toml --key <key-1> --key <key-2> --output-dir ./downloads
```

The Swift migration preserves the current local baseline: config validation,
credential path environment overrides, Gmail OAuth login/profile validation,
token-store status/revoke inspection,
attachment-cache lookup, cache pruning, and a read-only GraphQL-shaped JSON
envelope over accounts, threads, thread, message, attachment, and message file
metadata queries. File payloads are not returned through GraphQL. GraphQL file
metadata uses vendor-neutral `downloadKey` values; callers download a concrete
file only through `mail-gateway-reader file download`. Repeating `--key`
downloads multiple files in one command and returns a `files` array; single-key
downloads keep returning the existing single-file JSON object. Live Gmail
metadata retrieval is available for thread/message GraphQL queries when a
valid Gmail OAuth token store is configured. Thread search combines structured
filters such as `direction`, `labelIds`, `receivedAfter`, and `receivedBefore`
with the free-text Gmail `query` argument. It also accepts Gmail-backed star
filtering through `starred: true`.

```bash
mail-gateway-reader graphql --config ./config.toml \
  --query '{ threads(input: { accountId: "personal", starred: true, query: "from:alice@example.com" }) { totalCount } }'
```

`mail-gateway-reader` remains read-only and rejects `sendMessage` with
`SEND_DISABLED_IN_READER`. `mail-gateway-draft` accepts the same GraphQL
transport but maps `sendMessage` to Gmail draft creation by default.
`mail-gateway-sender` is the separate app for direct send and is the only
executable that maps `sendMessage` to Gmail message send. It also includes the
draft capability through `createDraft`.

```bash
mail-gateway-draft graphql --config ./config.toml \
  --query 'mutation { sendMessage(input: { accountId: "personal", to: ["you@example.com"], subject: "Draft", textBody: "Review before sending" }) { status operation draftId messageId } }'

mail-gateway-sender graphql --config ./config.toml \
  --query 'mutation { sendMessage(input: { accountId: "personal", to: ["you@example.com"], subject: "Send", textBody: "Send now" }) { status operation messageId threadId } }'

mail-gateway-sender graphql --config ./config.toml \
  --query 'mutation { createDraft(input: { accountId: "personal", to: ["you@example.com"], subject: "Draft from sender", textBody: "Review before sending" }) { status operation draftId messageId } }'
```

### File Downloads

GraphQL responses intentionally carry file metadata only. They can include
`downloadKey`, `kind`, `filename`, `mimeType`, `sizeBytes`, and
`materializationState`, but not body text, temporary-file bytes, or local payload
paths. This keeps LLM-facing GraphQL responses small; callers fetch only the
files they explicitly need through the gateway command.

Download one file:

```bash
mail-gateway-reader file download \
  --config ./config.toml \
  --key <download-key> \
  --output-dir ./downloads
```

Single-key output is the existing single-file JSON object with `localPath`.

Download multiple files in one command by repeating `--key`:

```bash
mail-gateway-reader file download \
  --config ./config.toml \
  --key <key-1> \
  --key <key-2> \
  --output-dir ./downloads
```

Multi-key output is a batch JSON object:

```json
{
  "fileCount": 2,
  "files": [
    {
      "kind": "BODY_TEXT",
      "filename": "body.txt",
      "localPath": "./downloads/gmail/message-1/body.txt"
    }
  ]
}
```

For batch downloads, files are copied under
`<output-dir>/<accountId>/<messageId>/<filename>` so files from different
messages cannot overwrite each other.

## Configuration

Configuration defaults to `$XDG_CONFIG_HOME/mail-gateway/config.toml`, or
`~/.config/mail-gateway/config.toml` when `XDG_CONFIG_HOME` is not set. It can be
overridden with `--config` or `MAIL_GATEWAY_CONFIG`.

If the implicit default config file does not exist, the reader uses built-in
local defaults so status and read-only local commands can still start:

- storage cache: `$XDG_DATA_HOME/mail-gateway`, or `~/.local/share/mail-gateway`
- attachment cache: `$XDG_CACHE_HOME/mail-gateway/attachments`, or
  `~/.cache/mail-gateway/attachments`
- send attachment root: `$XDG_DATA_HOME/mail-gateway/send-attachments`, or
  `~/.local/share/mail-gateway/send-attachments`
- credential id: `gmail-personal`
- account id: `personal`
- OAuth client JSON: `google-client.json` next to the default config path
- token store: `tokens/gmail-personal.json` next to the default config path

Explicit `--config` and `MAIL_GATEWAY_CONFIG` paths remain strict: if the named
file is missing or unreadable, loading fails.

Credential path overrides are supported per credential id:

- `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_OAUTH_CLIENT_SECRET_PATH`
- `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_TOKEN_STORE_PATH`
- `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_OAUTH_CLIENT_SECRET_JSON`
- `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_TOKEN_STORE_JSON`

`<CREDENTIAL_ID>` is derived from `credentials[].id` by uppercasing it and
replacing non-alphanumeric characters with `_`.

With the default credential id, kinko can provide these values through `.envrc`:

```bash
kinko set-key MAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_OAUTH_CLIENT_SECRET_PATH --value "$HOME/.config/mail-gateway/google-client.json"
kinko set-key MAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_TOKEN_STORE_PATH --value "$HOME/.config/mail-gateway/tokens/gmail-personal.json"
```

If the credential material should stay entirely in kinko instead of local files,
store the JSON values in:

```bash
MAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_OAUTH_CLIENT_SECRET_JSON
MAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_TOKEN_STORE_JSON
```

## Verification

```bash
swift build
swift run mail-gateway-swift-smoke-tests
task ci
git diff --check
```
