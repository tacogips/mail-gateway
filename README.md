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
```

The Swift migration preserves the current local baseline: config validation,
credential path environment overrides, token-store status/revoke inspection,
attachment-cache lookup, cache pruning, and a read-only GraphQL-shaped JSON
envelope over accounts, threads, thread, message, and attachment queries. Live
Gmail API retrieval and send workflows remain outside the current implemented
baseline.

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
