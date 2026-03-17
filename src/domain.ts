export type MailProvider = "gmail";
export type AccessMode = "read" | "read_send";
export type AuthState =
  | "MISSING"
  | "READY"
  | "EXPIRED"
  | "SCOPE_MISMATCH"
  | "INVALID"
  | "UNKNOWN";

export interface MailCapabilities {
  readonly canRead: boolean;
  readonly canSend: boolean;
  readonly configuredAccessMode: AccessMode;
  readonly authState: AuthState;
}

export interface MailAccount {
  readonly id: string;
  readonly provider: MailProvider;
  readonly emailAddress: string;
  readonly capabilities: MailCapabilities;
}

export interface MailAddress {
  readonly name: string | null;
  readonly address: string;
}

export type AttachmentMaterializationState =
  | "NOT_MATERIALIZED"
  | "CACHED"
  | "MATERIALIZED";

export interface GmailProviderMetadata {
  readonly labelIds: readonly string[];
  readonly historyId: string | null;
}

export interface ProviderMetadata {
  readonly gmail: GmailProviderMetadata | null;
}

export interface MailAttachment {
  readonly id: string;
  readonly filename: string | null;
  readonly mimeType: string;
  readonly sizeBytes: number | null;
  readonly localPath: string | null;
  readonly materializationState: AttachmentMaterializationState;
}

export interface MailMessage {
  readonly id: string;
  readonly threadId: string;
  readonly accountId: string;
  readonly subject: string | null;
  readonly from: readonly MailAddress[];
  readonly to: readonly MailAddress[];
  readonly cc: readonly MailAddress[];
  readonly bcc: readonly MailAddress[];
  readonly replyTo: readonly MailAddress[];
  readonly sentAt: string | null;
  readonly receivedAt: string | null;
  readonly textBody: string | null;
  readonly htmlBody: string | null;
  readonly attachments: readonly MailAttachment[];
  readonly providerMetadata: ProviderMetadata | null;
}

export interface MailThread {
  readonly id: string;
  readonly accountId: string;
  readonly subject: string | null;
  readonly snippet: string | null;
  readonly messages: readonly MailMessage[];
  readonly labels: readonly string[];
}

export interface PageInfo {
  readonly hasNextPage: boolean;
  readonly endCursor: string | null;
}

export interface MailThreadEdge {
  readonly cursor: string;
  readonly node: MailThread;
}

export interface ThreadConnection {
  readonly edges: readonly MailThreadEdge[];
  readonly pageInfo: PageInfo;
  readonly totalCount: number;
}

export interface ThreadSearchInput {
  readonly accountId: string;
  readonly query: string | null;
  readonly labelIds: readonly string[] | null;
  readonly unread: boolean | null;
  readonly from: readonly string[] | null;
  readonly hasAttachments: boolean | null;
  readonly direction: "SENT" | "RECEIVED" | "ALL" | null;
  readonly receivedAfter: string | null;
  readonly receivedBefore: string | null;
  readonly first: number;
  readonly after: string | null;
}

export interface AuthStatusReport {
  readonly credentialId: string;
  readonly provider: MailProvider;
  readonly configuredAccessMode: AccessMode;
  readonly state: AuthState;
  readonly tokenStorePath: string;
  readonly tokenStoreExists: boolean;
  readonly grantedAccessMode: AccessMode | null;
  readonly expiresAt: string | null;
  readonly hasRefreshToken: boolean;
}
