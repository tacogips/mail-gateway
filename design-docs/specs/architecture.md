# Architecture Design

This document describes system architecture and design decisions.

## Overview

Architectural patterns, system structure, and technical decisions.

## Mail Gateway Architecture

Detailed specification: [design-mail-gateway.md](./design-mail-gateway.md)

### System Summary

The first implementation ships `mail-gateway-reader` as a read-only local GraphQL gateway. A future `mail-gateway` binary will add send operations in Phase 2 without changing the core account/config model.

Gmail is the first provider, but the architecture separates provider adapters from the GraphQL and application layers so more providers can be added later without redesigning the core API.

### Core Architectural Decisions

- Use a canonical mail domain model (`MailAccount`, `MailThread`, `MailMessage`, `MailAttachment`) above provider adapters
- Separate credential profiles from mail accounts so multiple Gmail OAuth configurations and token stores can coexist
- Add explicit credential `access_mode` so auth scope and binary capability are machine-checkable
- Restrict payload hydration/materialization to the top-level attachment query; nested message and thread queries return attachment metadata only
- Keep attachment downloads in local storage, returning normalized local paths through GraphQL
- Return attachments only as materialized files with normalized local paths
- Ship a reduced schema in `mail-gateway-reader` so send operations are structurally unavailable

### Major Components

1. CLI and GraphQL transport layer
2. Application services for config loading, account resolution, and access checks
3. Provider adapter interface with Gmail as the first implementation
4. Local storage for token stores and attachment cache

### Initial Provider Scope

Gmail v1 uses the Gmail API and OAuth 2.0 installed-app flow. The adapter normalizes Gmail threads, messages, and MIME parts into the canonical domain model while preserving provider metadata for Gmail-specific fields when needed.

### Phase Boundaries

- Phase 1: `mail-gateway-reader` with `graphql`, `config validate`, `auth status`, `auth login`, `auth revoke`, and `cache prune`
- Phase 2: `mail-gateway` with outbound send support for new messages only
- `serve`, reply workflows, and draft workflows remain post-v1 scope

---
