# Design Notes

This document contains research findings, investigations, and miscellaneous design notes.

## Overview

Notable items that do not fit into architecture or client categories.

## Mail Gateway Notes

Detailed Gmail credential guidance: [design-gmail-credentials.md](./design-gmail-credentials.md)

### Working Assumptions

- The primary caller is a local AI client or automation agent, so a one-shot `graphql` command is the required first transport
- Gmail is the only provider in the first release, but the public design must not hard-code Gmail-only concepts into the canonical schema
- Local attachment materialization is acceptable in the reader binary because it does not mutate the remote mailbox

### Resolved Defaults

- Phase 1 ships only the one-shot `graphql` transport in `mail-gateway-reader`
- Materialized attachments are retained until explicit cleanup through `cache prune`
- Phase 2 send support starts with new outbound messages only
- Inline attachment payloads are not supported; attachments are exchanged only as files and local file paths to minimize AI token usage
- Credential profiles carry explicit `access_mode` so token scope mismatches can be surfaced by `auth status`
- Send attachment paths must stay under configured allowlist roots

### Design Rationale

- Separating credential profiles from account definitions is necessary because the same provider may be used with multiple OAuth client configurations and multiple token stores
- Returning attachment paths rather than binary blobs keeps GraphQL responses bounded for non-image files
- Restricting the reader binary at the schema level is safer than relying only on runtime authorization checks
- Requiring explicit `attachment(...)` hydration prevents broad read queries from unexpectedly downloading many files

---
