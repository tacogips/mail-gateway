import { GraphQLError, GraphQLScalarType, Kind } from "graphql";
import { createSchema, createYoga } from "graphql-yoga";

import type { MailGatewayConfig } from "./config";
import type {
  AccessMode,
  MailAccount,
  MailProvider,
  ThreadSearchInput,
} from "./domain";
import { AppError, EXIT_CODES, isAppError } from "./errors";
import { isRecord } from "./records";
import { MailGatewayReaderService } from "./service";

const readerSchemaSource = `
  scalar DateTime

  enum MailProvider {
    GMAIL
  }

  enum AuthState {
    MISSING
    READY
    EXPIRED
    SCOPE_MISMATCH
    INVALID
    UNKNOWN
  }

  enum AccessMode {
    READ
    READ_SEND
  }

  enum MailDirectionFilter {
    SENT
    RECEIVED
    ALL
  }

  enum AttachmentMaterializationState {
    NOT_MATERIALIZED
    CACHED
    MATERIALIZED
  }

  type MailCapabilities {
    canRead: Boolean!
    canSend: Boolean!
    configuredAccessMode: AccessMode!
    authState: AuthState!
  }

  type MailAccount {
    id: ID!
    provider: MailProvider!
    emailAddress: String!
    capabilities: MailCapabilities!
  }

  type MailAddress {
    name: String
    address: String!
  }

  type GmailProviderMetadata {
    labelIds: [String!]!
    historyId: String
  }

  type ProviderMetadata {
    gmail: GmailProviderMetadata
  }

  type MailAttachment {
    id: ID!
    filename: String
    mimeType: String!
    sizeBytes: Int
    localPath: String
    materializationState: AttachmentMaterializationState!
  }

  type MailMessage {
    id: ID!
    threadId: ID!
    accountId: ID!
    subject: String
    from: [MailAddress!]!
    to: [MailAddress!]!
    cc: [MailAddress!]!
    bcc: [MailAddress!]!
    replyTo: [MailAddress!]!
    sentAt: DateTime
    receivedAt: DateTime
    textBody: String
    htmlBody: String
    attachments: [MailAttachment!]!
    providerMetadata: ProviderMetadata
  }

  type MailThread {
    id: ID!
    accountId: ID!
    subject: String
    snippet: String
    messages: [MailMessage!]!
    labels: [String!]!
  }

  type MailThreadEdge {
    cursor: String!
    node: MailThread!
  }

  type PageInfo {
    hasNextPage: Boolean!
    endCursor: String
  }

  type ThreadConnection {
    edges: [MailThreadEdge!]!
    pageInfo: PageInfo!
    totalCount: Int!
  }

  input ThreadSearchInput {
    accountId: ID!
    query: String
    labelIds: [String!]
    unread: Boolean
    from: [String!]
    hasAttachments: Boolean
    direction: MailDirectionFilter
    receivedAfter: DateTime
    receivedBefore: DateTime
    first: Int = 20
    after: String
  }

  type Query {
    accounts: [MailAccount!]!
    account(id: ID!): MailAccount
    threads(input: ThreadSearchInput!): ThreadConnection!
    thread(accountId: ID!, threadId: ID!): MailThread
    message(accountId: ID!, messageId: ID!): MailMessage
    attachment(accountId: ID!, messageId: ID!, attachmentId: ID!): MailAttachment
  }
`;

interface ReaderGraphqlContext {
  readonly service: MailGatewayReaderService;
}

interface GraphqlErrorPayload {
  readonly message: string;
  readonly extensions: Readonly<Record<string, unknown>> | undefined;
}

interface GraphqlResponseBody {
  readonly data: unknown;
  readonly errors: readonly GraphqlErrorPayload[] | undefined;
}

const GRAPHQL_ACCESS_MODE = {
  read: "READ",
  read_send: "READ_SEND",
} as const satisfies Record<AccessMode, "READ" | "READ_SEND">;

const GRAPHQL_PROVIDER = {
  gmail: "GMAIL",
} as const satisfies Record<MailProvider, "GMAIL">;

const dateTimeScalar = new GraphQLScalarType<string | null, string | null>({
  name: "DateTime",
  serialize(value: unknown): string | null {
    if (value === null || value === undefined) {
      return null;
    }
    if (typeof value !== "string") {
      throw new GraphQLError("DateTime values must be strings");
    }
    return value;
  },
  parseValue(value: unknown): string | null {
    if (value === null) {
      return null;
    }
    if (typeof value !== "string") {
      throw new GraphQLError("DateTime values must be strings");
    }
    return value;
  },
  parseLiteral(valueNode): string | null {
    if (valueNode.kind === Kind.NULL) {
      return null;
    }
    if (valueNode.kind !== Kind.STRING) {
      throw new GraphQLError("DateTime values must be strings");
    }
    return valueNode.value;
  },
});

const readerSchema = createSchema<ReaderGraphqlContext>({
  typeDefs: readerSchemaSource,
  resolvers: {
    DateTime: dateTimeScalar,
    Query: {
      accounts: async (
        _parent: unknown,
        _args: Record<string, never>,
        context: ReaderGraphqlContext,
      ) => {
        return executeResolver(async () => {
          const accounts = await context.service.listAccounts();
          return accounts.map(normalizeAccountForGraphql);
        });
      },
      account: async (
        _parent: unknown,
        args: { readonly id: string },
        context: ReaderGraphqlContext,
      ) => {
        return executeResolver(async () => {
          const account = await context.service.getAccount(args.id);
          if (account === null) {
            return null;
          }
          return normalizeAccountForGraphql(account);
        });
      },
      threads: async (
        _parent: unknown,
        args: { readonly input: ThreadSearchInput },
        context: ReaderGraphqlContext,
      ) => {
        return executeResolver(async () => {
          return context.service.searchThreads(args.input);
        });
      },
      thread: async (
        _parent: unknown,
        args: { readonly accountId: string; readonly threadId: string },
        context: ReaderGraphqlContext,
      ) => {
        return executeResolver(async () => {
          return context.service.getThread(args.accountId, args.threadId);
        });
      },
      message: async (
        _parent: unknown,
        args: { readonly accountId: string; readonly messageId: string },
        context: ReaderGraphqlContext,
      ) => {
        return executeResolver(async () => {
          return context.service.getMessage(args.accountId, args.messageId);
        });
      },
      attachment: async (
        _parent: unknown,
        args: {
          readonly accountId: string;
          readonly messageId: string;
          readonly attachmentId: string;
        },
        context: ReaderGraphqlContext,
      ) => {
        return executeResolver(async () => {
          return context.service.getAttachment(
            args.accountId,
            args.messageId,
            args.attachmentId,
          );
        });
      },
    },
  },
});

function mapAppErrorToGraphQLError(error: AppError): GraphQLError {
  return new GraphQLError(error.message, {
    extensions: {
      code: error.code,
      exitCode: error.exitCode,
      ...(error.details === undefined ? {} : { details: error.details }),
    },
  });
}

function normalizeAccountForGraphql(
  account: MailAccount,
): Record<string, unknown> {
  return {
    ...account,
    provider: GRAPHQL_PROVIDER[account.provider],
    capabilities: {
      ...account.capabilities,
      configuredAccessMode:
        GRAPHQL_ACCESS_MODE[account.capabilities.configuredAccessMode],
    },
  };
}

async function executeResolver<T>(operation: () => Promise<T>): Promise<T> {
  try {
    return await operation();
  } catch (error: unknown) {
    if (isAppError(error)) {
      throw mapAppErrorToGraphQLError(error);
    }
    if (error instanceof GraphQLError) {
      throw error;
    }
    throw error;
  }
}

function readErrorPayload(value: unknown): GraphqlErrorPayload | null {
  if (!isRecord(value)) {
    return null;
  }

  const message = value["message"];
  if (typeof message !== "string") {
    return null;
  }

  const extensions = value["extensions"];
  return {
    message,
    extensions: isRecord(extensions) ? extensions : undefined,
  };
}

function parseGraphqlResponseBody(value: unknown): GraphqlResponseBody {
  if (!isRecord(value)) {
    return {
      data: null,
      errors: [
        {
          message: "Invalid GraphQL response",
          extensions: undefined,
        },
      ],
    };
  }

  const errorsValue = value["errors"];
  const errors = Array.isArray(errorsValue)
    ? errorsValue
        .map((entry) => readErrorPayload(entry))
        .filter((entry): entry is GraphqlErrorPayload => entry !== null)
    : undefined;

  return {
    data: value["data"] ?? null,
    errors,
  };
}

export async function executeReaderGraphql(input: {
  readonly config: MailGatewayConfig;
  readonly query: string;
  readonly variables: Record<string, unknown>;
}): Promise<{
  readonly body: Readonly<Record<string, unknown>>;
  readonly exitCode: 0 | 5;
}> {
  const service = new MailGatewayReaderService(input.config);
  const yoga = createYoga<{}, ReaderGraphqlContext>({
    schema: readerSchema,
    context: { service },
    graphiql: false,
    landingPage: false,
    logging: false,
    maskedErrors: false,
  });
  const response = await yoga.fetch("http://mail-gateway.local/graphql", {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      query: input.query,
      variables: input.variables,
    }),
  });
  const responseBody = parseGraphqlResponseBody(await response.json());
  const errors = responseBody.errors ?? [];

  return {
    body:
      errors.length === 0
        ? { data: responseBody.data }
        : {
            data: responseBody.data,
            errors: errors.map((error) => ({
              message: error.message,
              extensions: error.extensions,
            })),
          },
    exitCode:
      errors.length === 0
        ? EXIT_CODES.success
        : EXIT_CODES.graphqlExecutionError,
  };
}
