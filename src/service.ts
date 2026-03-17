import { mkdir, readdir, rm } from "node:fs/promises";
import {
  basename,
  isAbsolute,
  join,
  normalize,
  relative,
  resolve,
} from "node:path";

import type {
  MailGatewayConfig,
  AccountConfig,
  CredentialConfig,
} from "./config";
import type {
  AuthStatusReport,
  MailAccount,
  MailAttachment,
  MailCapabilities,
  ThreadConnection,
  ThreadSearchInput,
} from "./domain";
import { AppError, EXIT_CODES } from "./errors";
import { inspectTokenStore, revokeTokenStore } from "./token-store";

function sortById<T extends { readonly id: string }>(
  items: readonly T[],
): readonly T[] {
  return [...items].sort((left, right) => left.id.localeCompare(right.id));
}

function findCredential(
  config: MailGatewayConfig,
  credentialId: string,
): CredentialConfig {
  const credential = config.credentials.find(
    (item) => item.id === credentialId,
  );
  if (credential === undefined) {
    throw new AppError(
      `Unknown credential: ${credentialId}`,
      "CREDENTIAL_NOT_FOUND",
      EXIT_CODES.configurationError,
    );
  }
  return credential;
}

function findAccount(
  config: MailGatewayConfig,
  accountId: string,
): AccountConfig {
  const account = config.accounts.find((item) => item.id === accountId);
  if (account === undefined) {
    throw new AppError(
      `Unknown account: ${accountId}`,
      "ACCOUNT_NOT_FOUND",
      EXIT_CODES.graphqlExecutionError,
    );
  }
  return account;
}

function isWithinRoot(rootPath: string, candidatePath: string): boolean {
  const relativePath = relative(rootPath, candidatePath);
  return (
    relativePath === "" ||
    (!relativePath.startsWith("..") && !isAbsolute(relativePath))
  );
}

export class MailGatewayReaderService {
  readonly #config: MailGatewayConfig;
  readonly #attachmentRoot: string;
  readonly #allowedSendAttachmentRoots: readonly string[];

  constructor(config: MailGatewayConfig) {
    this.#config = config;
    this.#attachmentRoot = this.#normalizePath(config.storage.attachmentDir);
    this.#allowedSendAttachmentRoots =
      config.storage.allowedSendAttachmentRoots.map((root) =>
        this.#normalizePath(root),
      );
  }

  async listAccounts(): Promise<readonly MailAccount[]> {
    const accounts = await Promise.all(
      this.#config.accounts.map((account) => this.#buildMailAccount(account)),
    );

    return sortById(accounts);
  }

  async getAccount(accountId: string): Promise<MailAccount | null> {
    const account = this.#findAccount(accountId);
    if (account === undefined) {
      return null;
    }

    return this.#buildMailAccount(account);
  }

  async searchThreads(input: ThreadSearchInput): Promise<ThreadConnection> {
    this.#requireAccount(input.accountId);

    return {
      edges: [],
      pageInfo: {
        hasNextPage: false,
        endCursor: null,
      },
      totalCount: 0,
    };
  }

  async getThread(accountId: string, _threadId: string): Promise<null> {
    this.#requireAccount(accountId);
    return null;
  }

  async getMessage(accountId: string, _messageId: string): Promise<null> {
    this.#requireAccount(accountId);
    return null;
  }

  async getAttachment(
    accountId: string,
    messageId: string,
    attachmentId: string,
  ): Promise<MailAttachment | null> {
    this.#requireAccount(accountId);
    const attachmentDirectory = this.#getAttachmentDirectory(
      accountId,
      messageId,
    );

    const entries = await readdir(attachmentDirectory).catch(() => {
      return [];
    });
    const matchingEntry = entries.find((entry) =>
      entry.startsWith(`${attachmentId}-`),
    );
    if (matchingEntry === undefined) {
      return null;
    }

    const localPath = normalize(join(attachmentDirectory, matchingEntry));
    return {
      id: attachmentId,
      filename: basename(matchingEntry).replace(`${attachmentId}-`, "") || null,
      mimeType: "application/octet-stream",
      sizeBytes: null,
      localPath,
      materializationState: "CACHED",
    };
  }

  async getAuthStatus(credentialId: string): Promise<AuthStatusReport> {
    const credential = this.#requireCredential(credentialId);
    const tokenState = await inspectTokenStore(credential);

    return {
      credentialId: credential.id,
      provider: credential.provider,
      configuredAccessMode: credential.accessMode,
      state: tokenState.state,
      tokenStorePath: credential.tokenStorePath,
      tokenStoreExists: tokenState.exists,
      grantedAccessMode: tokenState.grantedAccessMode,
      expiresAt: tokenState.expiresAt,
      hasRefreshToken: tokenState.hasRefreshToken,
    };
  }

  async revokeAuth(
    credentialId: string,
  ): Promise<{ readonly revoked: boolean }> {
    const credential = this.#requireCredential(credentialId);
    const revoked = await revokeTokenStore(credential);
    return { revoked };
  }

  async login(credentialId: string): Promise<never> {
    const credential = this.#requireCredential(credentialId);
    throw new AppError(
      `Interactive auth bootstrap is not implemented for provider ${credential.provider}`,
      "AUTH_BOOTSTRAP_NOT_IMPLEMENTED",
      EXIT_CODES.authenticationBootstrapError,
      { credentialId },
    );
  }

  async pruneCache(input: {
    readonly accountId: string | null;
    readonly all: boolean;
  }): Promise<{ readonly prunedPaths: readonly string[] }> {
    if (!input.all && input.accountId === null) {
      throw new AppError(
        "cache prune requires --all or --account",
        "INVALID_ARGUMENT",
        EXIT_CODES.invalidCliUsage,
      );
    }
    if (input.all && input.accountId !== null) {
      throw new AppError(
        "cache prune accepts either --all or --account, but not both",
        "INVALID_ARGUMENT",
        EXIT_CODES.invalidCliUsage,
      );
    }

    const targets =
      input.all || input.accountId === null
        ? [this.#attachmentRoot]
        : [
            join(
              this.#attachmentRoot,
              this.#requireAccount(input.accountId).id,
            ),
          ];

    await mkdir(this.#attachmentRoot, {
      recursive: true,
      mode: 0o700,
    });

    const prunedPaths: string[] = [];
    for (const target of targets) {
      const normalizedTarget = this.#assertWithinAttachmentRoot(target);
      await rm(normalizedTarget, { recursive: true, force: true });
      if (input.all) {
        await mkdir(this.#attachmentRoot, { recursive: true, mode: 0o700 });
      }
      prunedPaths.push(normalizedTarget);
    }

    return { prunedPaths };
  }

  async validateSendAttachmentPath(candidatePath: string): Promise<string> {
    const normalizedCandidate = this.#normalizePath(candidatePath);
    const isAllowed = this.#allowedSendAttachmentRoots.some((root) => {
      return isWithinRoot(root, normalizedCandidate);
    });

    if (!isAllowed) {
      throw new AppError(
        "Attachment path is outside allowed_send_attachment_roots",
        "CONFIG_INVALID",
        EXIT_CODES.configurationError,
        { candidatePath: normalizedCandidate },
      );
    }

    return normalizedCandidate;
  }

  async #buildMailAccount(account: AccountConfig): Promise<MailAccount> {
    const credential = this.#requireCredential(account.credentialId);
    const tokenState = await inspectTokenStore(credential);

    return {
      id: account.id,
      provider: account.provider,
      emailAddress: account.emailAddress,
      capabilities: this.#buildMailCapabilities(credential, tokenState.state),
    };
  }

  #findAccount(accountId: string): AccountConfig | undefined {
    return this.#config.accounts.find((item) => item.id === accountId);
  }

  #requireAccount(accountId: string): AccountConfig {
    return findAccount(this.#config, accountId);
  }

  #requireCredential(credentialId: string): CredentialConfig {
    return findCredential(this.#config, credentialId);
  }

  #buildMailCapabilities(
    credential: CredentialConfig,
    authState: MailCapabilities["authState"],
  ): MailCapabilities {
    return {
      canRead: true,
      canSend: false,
      configuredAccessMode: credential.accessMode,
      authState,
    };
  }

  #getAttachmentDirectory(accountId: string, messageId: string): string {
    return join(this.#attachmentRoot, accountId, messageId);
  }

  #normalizePath(path: string): string {
    return normalize(resolve(path));
  }

  #assertWithinAttachmentRoot(target: string): string {
    const normalizedTarget = this.#normalizePath(target);
    if (!isWithinRoot(this.#attachmentRoot, normalizedTarget)) {
      throw new AppError(
        "Refusing to prune outside the configured attachment root",
        "CONFIG_INVALID",
        EXIT_CODES.configurationError,
        { target: normalizedTarget, storageRoot: this.#attachmentRoot },
      );
    }

    return normalizedTarget;
  }
}
