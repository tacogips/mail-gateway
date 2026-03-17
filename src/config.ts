import { access, readFile } from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import { dirname, isAbsolute, normalize, resolve } from "node:path";
import { homedir } from "node:os";

import type { AccessMode, MailProvider } from "./domain";
import { AppError, EXIT_CODES } from "./errors";
import { isRecord, type RecordValue } from "./records";

export interface StorageConfig {
  readonly cacheDir: string;
  readonly attachmentDir: string;
  readonly allowedSendAttachmentRoots: readonly string[];
}

export interface CredentialConfig {
  readonly id: string;
  readonly provider: MailProvider;
  readonly accessMode: AccessMode;
  readonly oauthClientSecretPath: string;
  readonly tokenStorePath: string;
}

export interface AccountConfig {
  readonly id: string;
  readonly provider: MailProvider;
  readonly emailAddress: string;
  readonly credentialId: string;
  readonly defaultLabelIds: readonly string[];
}

export interface MailGatewayConfig {
  readonly configPath: string;
  readonly storage: StorageConfig;
  readonly credentials: readonly CredentialConfig[];
  readonly accounts: readonly AccountConfig[];
}

type JsonRecord = RecordValue;
export type CredentialPathKey = "oauth_client_secret_path" | "token_store_path";

const DEFAULT_CONFIG_PATH_SEGMENTS = ["mail-gateway", "config.toml"] as const;

function readRecord(value: unknown, context: string): JsonRecord {
  if (!isRecord(value)) {
    throw new AppError(
      `${context} must be a table/object`,
      "CONFIG_INVALID",
      EXIT_CODES.configurationError,
    );
  }
  return value;
}

function readString(value: unknown, context: string): string {
  if (typeof value !== "string" || value.trim() === "") {
    throw new AppError(
      `${context} must be a non-empty string`,
      "CONFIG_INVALID",
      EXIT_CODES.configurationError,
    );
  }
  return value;
}

function readOptionalString(
  value: unknown,
  context: string,
): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  return readString(value, context);
}

function readOptionalStringArray(
  value: unknown,
  context: string,
): readonly string[] {
  if (value === undefined) {
    return [];
  }
  if (!Array.isArray(value)) {
    throw new AppError(
      `${context} must be an array of strings`,
      "CONFIG_INVALID",
      EXIT_CODES.configurationError,
    );
  }

  return value.map((item, index) => readString(item, `${context}[${index}]`));
}

function resolveConfigRelativePath(
  configPath: string,
  rawPath: string,
): string {
  const normalized = isAbsolute(rawPath)
    ? normalize(rawPath)
    : normalize(resolve(dirname(configPath), rawPath));

  return normalized;
}

function credentialIdToEnvSuffix(credentialId: string): string {
  const normalized = credentialId
    .trim()
    .replace(/[^A-Za-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .toUpperCase();

  return normalized.length > 0 ? normalized : "CREDENTIAL";
}

export function getCredentialPathEnvVarName(
  credentialId: string,
  pathKey: CredentialPathKey,
): string {
  const suffix = credentialIdToEnvSuffix(credentialId);
  if (pathKey === "oauth_client_secret_path") {
    return `MAIL_GATEWAY_CREDENTIAL_${suffix}_OAUTH_CLIENT_SECRET_PATH`;
  }
  return `MAIL_GATEWAY_CREDENTIAL_${suffix}_TOKEN_STORE_PATH`;
}

function resolveCredentialPath(options: {
  readonly configPath: string;
  readonly credentialId: string;
  readonly pathKey: CredentialPathKey;
  readonly configValue: string | undefined;
  readonly env: NodeJS.ProcessEnv;
  readonly context: string;
}): string {
  const envVarName = getCredentialPathEnvVarName(
    options.credentialId,
    options.pathKey,
  );
  const envValue = options.env[envVarName];
  const selectedValue =
    typeof envValue === "string" && envValue.trim() !== ""
      ? envValue
      : options.configValue;

  if (selectedValue === undefined) {
    throw new AppError(
      `${options.context} must be set in config or ${envVarName}`,
      "CONFIG_INVALID",
      EXIT_CODES.configurationError,
    );
  }

  return resolveConfigRelativePath(options.configPath, selectedValue);
}

function readProvider(value: unknown, context: string): MailProvider {
  const provider = readString(value, context);
  if (provider !== "gmail") {
    throw new AppError(
      `${context} must currently be "gmail"`,
      "CONFIG_INVALID",
      EXIT_CODES.configurationError,
    );
  }
  return provider;
}

function readAccessMode(value: unknown, context: string): AccessMode {
  const accessMode = value === undefined ? "read" : readString(value, context);
  if (accessMode !== "read" && accessMode !== "read_send") {
    throw new AppError(
      `${context} must be "read" or "read_send"`,
      "CONFIG_INVALID",
      EXIT_CODES.configurationError,
    );
  }
  return accessMode;
}

function ensureUnique(values: readonly string[], context: string): void {
  const seen = new Set<string>();
  for (const value of values) {
    if (seen.has(value)) {
      throw new AppError(
        `${context} contains a duplicate value: ${value}`,
        "CONFIG_INVALID",
        EXIT_CODES.configurationError,
      );
    }
    seen.add(value);
  }
}

async function assertFileReadable(
  path: string,
  context: string,
): Promise<void> {
  try {
    await access(path, fsConstants.R_OK);
  } catch {
    throw new AppError(
      `${context} is not readable: ${path}`,
      "CONFIG_INVALID",
      EXIT_CODES.configurationError,
    );
  }
}

function readNonEmptyArray(
  value: unknown,
  context: string,
): readonly unknown[] {
  if (!Array.isArray(value) || value.length === 0) {
    throw new AppError(
      `${context} must be a non-empty array`,
      "CONFIG_INVALID",
      EXIT_CODES.configurationError,
    );
  }

  return value;
}

function resolveConfiguredPath(
  configPath: string | undefined,
  env: NodeJS.ProcessEnv,
): string {
  return normalize(
    resolve(
      configPath ?? env["MAIL_GATEWAY_CONFIG"] ?? resolveDefaultConfigPath(env),
    ),
  );
}

function parseStorageConfig(
  storageRecord: JsonRecord,
  absoluteConfigPath: string,
): StorageConfig {
  return {
    cacheDir: resolveConfigRelativePath(
      absoluteConfigPath,
      readString(storageRecord["cache_dir"], "storage.cache_dir"),
    ),
    attachmentDir: resolveConfigRelativePath(
      absoluteConfigPath,
      readString(storageRecord["attachment_dir"], "storage.attachment_dir"),
    ),
    allowedSendAttachmentRoots: readOptionalStringArray(
      storageRecord["allowed_send_attachment_roots"],
      "storage.allowed_send_attachment_roots",
    ).map((root) => resolveConfigRelativePath(absoluteConfigPath, root)),
  };
}

function parseCredentialConfig(
  rawCredential: unknown,
  index: number,
  absoluteConfigPath: string,
  env: NodeJS.ProcessEnv,
): CredentialConfig {
  const credential = readRecord(rawCredential, `credentials[${index}]`);
  const contextBase = `credentials[${index}]`;
  const credentialId = readString(credential["id"], `${contextBase}.id`);

  return {
    id: credentialId,
    provider: readProvider(credential["provider"], `${contextBase}.provider`),
    accessMode: readAccessMode(
      credential["access_mode"],
      `${contextBase}.access_mode`,
    ),
    oauthClientSecretPath: resolveCredentialPath({
      configPath: absoluteConfigPath,
      credentialId,
      pathKey: "oauth_client_secret_path",
      configValue: readOptionalString(
        credential["oauth_client_secret_path"],
        `${contextBase}.oauth_client_secret_path`,
      ),
      env,
      context: `${contextBase}.oauth_client_secret_path`,
    }),
    tokenStorePath: resolveCredentialPath({
      configPath: absoluteConfigPath,
      credentialId,
      pathKey: "token_store_path",
      configValue: readOptionalString(
        credential["token_store_path"],
        `${contextBase}.token_store_path`,
      ),
      env,
      context: `${contextBase}.token_store_path`,
    }),
  };
}

function parseAccountConfig(rawAccount: unknown, index: number): AccountConfig {
  const account = readRecord(rawAccount, `accounts[${index}]`);
  const contextBase = `accounts[${index}]`;
  const emailAddress = readString(
    account["email_address"],
    `${contextBase}.email_address`,
  );
  if (!emailAddress.includes("@")) {
    throw new AppError(
      `${contextBase}.email_address must contain @`,
      "CONFIG_INVALID",
      EXIT_CODES.configurationError,
    );
  }

  return {
    id: readString(account["id"], `${contextBase}.id`),
    provider: readProvider(account["provider"], `${contextBase}.provider`),
    emailAddress,
    credentialId: readString(
      account["credential_id"],
      `${contextBase}.credential_id`,
    ),
    defaultLabelIds: readOptionalStringArray(
      account["default_label_ids"],
      `${contextBase}.default_label_ids`,
    ),
  };
}

function validateAccountCredentialLinks(
  credentials: readonly CredentialConfig[],
  accounts: readonly AccountConfig[],
): void {
  const credentialsById = new Map(
    credentials.map((credential) => [credential.id, credential]),
  );

  for (const account of accounts) {
    const credential = credentialsById.get(account.credentialId);
    if (credential === undefined) {
      throw new AppError(
        `accounts.${account.id} references unknown credential: ${account.credentialId}`,
        "CONFIG_INVALID",
        EXIT_CODES.configurationError,
      );
    }

    if (credential.provider !== account.provider) {
      throw new AppError(
        `accounts.${account.id} provider does not match credential provider`,
        "CONFIG_INVALID",
        EXIT_CODES.configurationError,
      );
    }
  }
}

export function resolveDefaultConfigPath(
  env: NodeJS.ProcessEnv = process.env,
): string {
  const xdgConfigHome = env["XDG_CONFIG_HOME"];
  if (typeof xdgConfigHome === "string" && xdgConfigHome.trim() !== "") {
    return normalize(resolve(xdgConfigHome, ...DEFAULT_CONFIG_PATH_SEGMENTS));
  }

  return normalize(
    resolve(homedir(), ".config", ...DEFAULT_CONFIG_PATH_SEGMENTS),
  );
}

export async function loadConfig(
  configPath?: string,
  env: NodeJS.ProcessEnv = process.env,
): Promise<MailGatewayConfig> {
  const absoluteConfigPath = resolveConfiguredPath(configPath, env);
  const source = await readFile(absoluteConfigPath, "utf8").catch(
    (error: unknown) => {
      throw new AppError(
        `Failed to read config: ${absoluteConfigPath}`,
        "CONFIG_INVALID",
        EXIT_CODES.configurationError,
        { cause: error instanceof Error ? error.message : String(error) },
      );
    },
  );

  const parsed = readRecord(Bun.TOML.parse(source), "config");
  const storageRecord = readRecord(parsed["storage"], "storage");
  const credentialsArray = readNonEmptyArray(
    parsed["credentials"],
    "credentials",
  );
  const accountsArray = readNonEmptyArray(parsed["accounts"], "accounts");

  const storage = parseStorageConfig(storageRecord, absoluteConfigPath);
  const credentials = credentialsArray.map((rawCredential, index) =>
    parseCredentialConfig(rawCredential, index, absoluteConfigPath, env),
  );
  const accounts = accountsArray.map((rawAccount, index) =>
    parseAccountConfig(rawAccount, index),
  );

  ensureUnique(
    credentials.map((credential) => credential.id),
    "credentials.id",
  );
  ensureUnique(
    accounts.map((account) => account.id),
    "accounts.id",
  );
  ensureUnique(
    credentials.map((credential) => credential.tokenStorePath),
    "credentials.token_store_path",
  );

  validateAccountCredentialLinks(credentials, accounts);

  for (const credential of credentials) {
    await assertFileReadable(
      credential.oauthClientSecretPath,
      `credentials.${credential.id}.oauth_client_secret_path`,
    );
  }

  return {
    configPath: absoluteConfigPath,
    storage,
    credentials,
    accounts,
  };
}

export interface ConfigValidationSummary {
  readonly ok: true;
  readonly configPath: string;
  readonly accountIds: readonly string[];
  readonly credentialIds: readonly string[];
}

export async function validateConfig(
  configPath?: string,
  env: NodeJS.ProcessEnv = process.env,
): Promise<ConfigValidationSummary> {
  const config = await loadConfig(configPath, env);
  return {
    ok: true,
    configPath: config.configPath,
    accountIds: config.accounts.map((account) => account.id),
    credentialIds: config.credentials.map((credential) => credential.id),
  };
}
