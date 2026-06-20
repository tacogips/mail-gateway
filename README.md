# mail-gateway

AI-oriented local mail gateway implemented as a Swift package.

The package exposes:

- `MailGatewayCore`: Swift library for config loading, reader service behavior, and CLI execution
- `mail-gateway-reader`: Phase 1 read-only command surface
- `mail-gateway-swift-smoke-tests`: executable verification harness

## Build

```bash
swift build -c release --product mail-gateway-reader
```

```bash
task install-reader PREFIX="$HOME/.local"
```

## Commands

`mail-gateway-reader` supports the Phase 1 local reader surface:

```bash
mail-gateway-reader config validate --config ./config.toml --pretty
mail-gateway-reader auth status --config ./config.toml --credential gmail-personal
mail-gateway-reader auth revoke --config ./config.toml --credential gmail-personal
mail-gateway-reader cache prune --config ./config.toml --account personal
mail-gateway-reader graphql --config ./config.toml --query '{ accounts { id emailAddress } }'
mail-gateway-reader file download --config ./config.toml --key <download-key> --output-dir ./downloads
mail-gateway-reader file download --config ./config.toml --key <key-1> --key <key-2> --output-dir ./downloads
```

The Swift migration preserves the current local baseline: config validation,
credential path environment overrides, token-store status/revoke inspection,
attachment-cache lookup, cache pruning, and a read-only GraphQL-shaped JSON
envelope over accounts, threads, thread, message, attachment, and message file
metadata queries. File payloads are not returned through GraphQL. GraphQL file
metadata uses vendor-neutral `downloadKey` values; callers download a concrete
file only through `mail-gateway-reader file download`. Repeating `--key`
downloads multiple files in one command and returns a `files` array; single-key
downloads keep returning the existing single-file JSON object. Live Gmail API
retrieval and send workflows remain outside the current implemented baseline.

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

Credential path overrides are supported per credential id:

- `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_OAUTH_CLIENT_SECRET_PATH`
- `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_TOKEN_STORE_PATH`

`<CREDENTIAL_ID>` is derived from `credentials[].id` by uppercasing it and
replacing non-alphanumeric characters with `_`.

## Verification

```bash
swift build
swift run mail-gateway-swift-smoke-tests
task ci
git diff --check
```
