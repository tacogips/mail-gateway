# Design References

This directory contains reference materials for system design and implementation.

## External References

| Name | URL | Description |
|------|-----|-------------|
| TypeScript Documentation | https://www.typescriptlang.org/docs/ | Official TypeScript documentation |
| Bun Documentation | https://bun.sh/docs | Official Bun runtime documentation |
| Gmail API Overview | https://developers.google.com/workspace/gmail/api/guides | Official Gmail API concepts and resource model |
| Gmail API Reference | https://developers.google.com/workspace/gmail/api/reference/rest | Official Gmail REST resource reference |
| Gmail API Sending Guide | https://developers.google.com/workspace/gmail/api/guides/sending | Official Gmail sending patterns |
| Gmail API Scopes | https://developers.google.com/workspace/gmail/api/auth/scopes | Official Gmail OAuth scope classifications and descriptions |
| Gmail API Node.js Quickstart | https://developers.google.com/workspace/gmail/api/quickstart/nodejs | Official quickstart showing desktop-app OAuth client setup |
| OAuth 2.0 for iOS and Desktop Apps | https://developers.google.com/identity/protocols/oauth2/native-app | Official Google installed-app OAuth guidance |
| OAuth 2.0 Policies | https://developers.google.com/identity/protocols/oauth2/policies | Official least-privilege and consent-screen policy guidance |
| Restricted Scope Verification | https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification | Official verification and restricted-scope requirements |
| GraphQL Learn | https://graphql.org/learn/ | Official GraphQL concepts and schema guidance |

## Reference Documents

Reference documents should be organized by topic:

```
references/
├── README.md              # This index file
├── typescript/            # TypeScript patterns and practices
└── <topic>/               # Other topic-specific references
```

## Adding References

When adding new reference materials:

1. Create a topic directory if it does not exist
2. Add reference documents with clear naming
3. Update this README.md with the reference entry
