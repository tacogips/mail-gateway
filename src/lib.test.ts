import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { afterEach, describe, expect, test } from "bun:test";

import {
  getCredentialPathEnvVarName,
  loadConfig,
  runCli,
  type CredentialPathKey,
} from "./lib";

const CREDENTIAL_ID = "gmail-personal";

interface FixtureOptions {
  readonly includeCredentialPaths?: boolean;
  readonly oauthClientSecretPathValue?: string;
  readonly tokenStorePathValue?: string;
}

interface TestFixture {
  readonly clientSecretPath: string;
  readonly rootDir: string;
  readonly configPath: string;
  readonly attachmentRoot: string;
  readonly sendRoot: string;
  readonly tokenPath: string;
}

class MemoryWriter {
  readonly #chunks: string[] = [];

  write(chunk: string): boolean {
    this.#chunks.push(chunk);
    return true;
  }

  toString(): string {
    return this.#chunks.join("");
  }
}

async function createFixture(
  options: FixtureOptions = {},
): Promise<TestFixture> {
  const rootDir = await mkdtemp(join(tmpdir(), "mail-gateway-"));
  const configDir = join(rootDir, "config");
  const cacheDir = join(rootDir, "cache");
  const attachmentRoot = join(rootDir, "attachments");
  const sendRoot = join(rootDir, "send");
  const secretsDir = join(rootDir, "secrets");
  const tokensDir = join(rootDir, "tokens");

  await mkdir(configDir, { recursive: true });
  await mkdir(cacheDir, { recursive: true });
  await mkdir(attachmentRoot, { recursive: true });
  await mkdir(sendRoot, { recursive: true });
  await mkdir(secretsDir, { recursive: true });
  await mkdir(tokensDir, { recursive: true });

  const clientSecretPath = join(secretsDir, "client.json");
  const tokenPath = join(tokensDir, "account.json");
  await writeFile(clientSecretPath, '{"installed":true}\n', "utf8");

  const configPath = join(configDir, "config.toml");
  const includeCredentialPaths = options.includeCredentialPaths ?? true;
  const credentialPathLines = includeCredentialPaths
    ? [
        `oauth_client_secret_path = "${options.oauthClientSecretPathValue ?? "../secrets/client.json"}"`,
        `token_store_path = "${options.tokenStorePathValue ?? "../tokens/account.json"}"`,
      ]
    : [];
  await writeFile(
    configPath,
    `
[storage]
cache_dir = "../cache"
attachment_dir = "../attachments"
allowed_send_attachment_roots = ["../send"]

[[credentials]]
id = "${CREDENTIAL_ID}"
provider = "gmail"
access_mode = "read"
${credentialPathLines.join("\n")}

[[accounts]]
id = "personal"
provider = "gmail"
email_address = "person@example.com"
credential_id = "${CREDENTIAL_ID}"
default_label_ids = ["INBOX"]
`.trimStart(),
    "utf8",
  );

  return {
    clientSecretPath,
    rootDir,
    configPath,
    attachmentRoot,
    sendRoot,
    tokenPath,
  };
}

async function useFixture(options: FixtureOptions = {}): Promise<TestFixture> {
  const fixture = await createFixture(options);
  rootsToCleanup.push(fixture.rootDir);
  return fixture;
}

const rootsToCleanup: string[] = [];

afterEach(async () => {
  while (rootsToCleanup.length > 0) {
    const root = rootsToCleanup.pop();
    if (root !== undefined) {
      await rm(root, { recursive: true, force: true });
    }
  }
});

function buildCredentialEnv(
  fixture: TestFixture,
  overrides: Partial<Record<CredentialPathKey, string>> = {},
): NodeJS.ProcessEnv {
  return {
    [getCredentialPathEnvVarName(CREDENTIAL_ID, "oauth_client_secret_path")]:
      overrides.oauth_client_secret_path ?? fixture.clientSecretPath,
    [getCredentialPathEnvVarName(CREDENTIAL_ID, "token_store_path")]:
      overrides.token_store_path ?? fixture.tokenPath,
  };
}

async function runCliWithCapture(
  argv: readonly string[],
  options: {
    readonly env?: NodeJS.ProcessEnv;
  } = {},
): Promise<{
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
}> {
  const stdout = new MemoryWriter();
  const stderr = new MemoryWriter();
  const exitCode = await runCli(argv, {
    stdout,
    stderr,
    ...(options.env === undefined ? {} : { env: options.env }),
  });

  return {
    exitCode,
    stdout: stdout.toString(),
    stderr: stderr.toString(),
  };
}

describe("config loading", () => {
  test("resolves relative paths and validates required files", async () => {
    const fixture = await useFixture();

    const config = await loadConfig(fixture.configPath);

    expect(config.storage.attachmentDir).toBe(fixture.attachmentRoot);
    expect(config.storage.allowedSendAttachmentRoots).toEqual([
      fixture.sendRoot,
    ]);
    expect(config.credentials[0]?.accessMode).toBe("read");
  });

  test("accepts env-only credential paths when toml omits them", async () => {
    const fixture = await useFixture({
      includeCredentialPaths: false,
    });

    const config = await loadConfig(
      fixture.configPath,
      buildCredentialEnv(fixture),
    );

    expect(config.credentials[0]?.oauthClientSecretPath).toBe(
      fixture.clientSecretPath,
    );
    expect(config.credentials[0]?.tokenStorePath).toBe(fixture.tokenPath);
  });

  test("prefers env credential paths over toml values", async () => {
    const fixture = await useFixture();

    const alternateSecretsDir = join(fixture.rootDir, "alt-secrets");
    const alternateTokensDir = join(fixture.rootDir, "alt-tokens");
    await mkdir(alternateSecretsDir, { recursive: true });
    await mkdir(alternateTokensDir, { recursive: true });

    const alternateClientSecretPath = join(alternateSecretsDir, "client.json");
    const alternateTokenPath = join(alternateTokensDir, "account.json");
    await writeFile(alternateClientSecretPath, '{"installed":true}\n', "utf8");

    const config = await loadConfig(
      fixture.configPath,
      buildCredentialEnv(fixture, {
        oauth_client_secret_path: alternateClientSecretPath,
        token_store_path: alternateTokenPath,
      }),
    );

    expect(config.credentials[0]?.oauthClientSecretPath).toBe(
      alternateClientSecretPath,
    );
    expect(config.credentials[0]?.tokenStorePath).toBe(alternateTokenPath);
  });

  test("accepts boolean flags before the command positionals", async () => {
    const fixture = await useFixture();

    const result = await runCliWithCapture([
      "--pretty",
      "config",
      "validate",
      "--config",
      fixture.configPath,
    ]);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain('\n  "ok": true');
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      configPath: fixture.configPath,
    });
  });

  test("uses cli env for config validation when credential paths come only from env", async () => {
    const fixture = await useFixture({
      includeCredentialPaths: false,
    });

    const result = await runCliWithCapture(
      ["config", "validate", "--config", fixture.configPath],
      {
        env: {
          MAIL_GATEWAY_CONFIG: fixture.configPath,
          ...buildCredentialEnv(fixture),
        },
      },
    );

    expect(result.exitCode).toBe(0);
    expect(result.stderr).toBe("");
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      configPath: fixture.configPath,
    });
  });
});

describe("auth status", () => {
  test("reports missing token state", async () => {
    const fixture = await useFixture();

    const result = await runCliWithCapture([
      "auth",
      "status",
      "--config",
      fixture.configPath,
      "--credential",
      CREDENTIAL_ID,
    ]);

    expect(result.exitCode).toBe(0);
    expect(result.stderr).toBe("");
    expect(JSON.parse(result.stdout)).toMatchObject({
      credentialId: CREDENTIAL_ID,
      state: "MISSING",
      tokenStoreExists: false,
    });
  });

  test("reports scope mismatch when token metadata disagrees with config", async () => {
    const fixture = await useFixture();
    await writeFile(
      fixture.tokenPath,
      JSON.stringify({
        accessMode: "read_send",
        refreshToken: "refresh-token",
      }),
      "utf8",
    );

    const result = await runCliWithCapture([
      "auth",
      "status",
      "--config",
      fixture.configPath,
      "--credential",
      CREDENTIAL_ID,
    ]);

    expect(result.exitCode).toBe(0);
    expect(JSON.parse(result.stdout)).toMatchObject({
      state: "SCOPE_MISMATCH",
      grantedAccessMode: "read_send",
    });
  });

  test("reports revoke=false when the token store does not exist", async () => {
    const fixture = await useFixture();

    const result = await runCliWithCapture([
      "auth",
      "revoke",
      "--config",
      fixture.configPath,
      "--credential",
      CREDENTIAL_ID,
    ]);

    expect(result.exitCode).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({
      credentialId: CREDENTIAL_ID,
      revoked: false,
    });
  });
});

describe("graphql command", () => {
  test("returns accounts with resolved capabilities", async () => {
    const fixture = await useFixture();

    const result = await runCliWithCapture([
      "graphql",
      "--config",
      fixture.configPath,
      "--query",
      "{ accounts { id provider emailAddress capabilities { canRead canSend configuredAccessMode authState } } }",
    ]);

    expect(result.exitCode).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({
      data: {
        accounts: [
          {
            id: "personal",
            provider: "GMAIL",
            emailAddress: "person@example.com",
            capabilities: {
              canRead: true,
              canSend: false,
              configuredAccessMode: "READ",
              authState: "MISSING",
            },
          },
        ],
      },
    });
  });

  test("rejects invalid inline variables JSON as cli usage", async () => {
    const fixture = await useFixture();

    const result = await runCliWithCapture([
      "graphql",
      "--config",
      fixture.configPath,
      "--query",
      "{ accounts { id } }",
      "--variables",
      "{bad-json}",
    ]);

    expect(result.exitCode).toBe(2);
    expect(JSON.parse(result.stderr)).toMatchObject({
      error: {
        code: "INVALID_ARGUMENT",
        message: "--variables must be valid JSON",
        exitCode: 2,
      },
    });
  });

  test("rejects invalid variables-file JSON as cli usage", async () => {
    const fixture = await useFixture();

    const variablesPath = join(fixture.rootDir, "variables.json");
    await writeFile(variablesPath, "{bad-json}", "utf8");

    const result = await runCliWithCapture([
      "graphql",
      "--config",
      fixture.configPath,
      "--query",
      "{ accounts { id } }",
      "--variables-file",
      variablesPath,
    ]);

    expect(result.exitCode).toBe(2);
    expect(JSON.parse(result.stderr)).toMatchObject({
      error: {
        code: "INVALID_ARGUMENT",
        message: `Failed to parse JSON variables file: ${variablesPath}`,
        exitCode: 2,
      },
    });
  });

  test("rejects missing query-file as cli usage", async () => {
    const fixture = await useFixture();

    const queryPath = join(fixture.rootDir, "missing.graphql");
    const result = await runCliWithCapture([
      "graphql",
      "--config",
      fixture.configPath,
      "--query-file",
      queryPath,
    ]);

    expect(result.exitCode).toBe(2);
    expect(JSON.parse(result.stderr)).toMatchObject({
      error: {
        code: "INVALID_ARGUMENT",
        message: `Failed to read GraphQL query file: ${queryPath}`,
        exitCode: 2,
      },
    });
  });

  test("resolves cached attachments only through the attachment query", async () => {
    const fixture = await useFixture();

    const messageDir = join(fixture.attachmentRoot, "personal", "message-1");
    await mkdir(messageDir, { recursive: true });
    await writeFile(
      join(messageDir, "attachment-1-report.pdf"),
      "payload",
      "utf8",
    );

    const result = await runCliWithCapture([
      "graphql",
      "--config",
      fixture.configPath,
      "--query",
      '{ attachment(accountId: "personal", messageId: "message-1", attachmentId: "attachment-1") { id filename localPath materializationState } }',
    ]);

    expect(result.exitCode).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({
      data: {
        attachment: {
          id: "attachment-1",
          filename: "report.pdf",
          localPath: join(messageDir, "attachment-1-report.pdf"),
          materializationState: "CACHED",
        },
      },
    });
  });

  test("returns graphql errors for app-level execution failures", async () => {
    const fixture = await useFixture();

    const result = await runCliWithCapture([
      "graphql",
      "--config",
      fixture.configPath,
      "--query",
      '{ threads(input: { accountId: "missing-account" }) { totalCount } }',
    ]);

    expect(result.exitCode).toBe(5);
    expect(JSON.parse(result.stdout)).toEqual({
      data: null,
      errors: [
        {
          message: "Unknown account: missing-account",
          extensions: {
            code: "ACCOUNT_NOT_FOUND",
            exitCode: 5,
          },
        },
      ],
    });
  });
});

describe("cache prune", () => {
  test("removes only the requested account subtree", async () => {
    const fixture = await useFixture();

    const accountDir = join(fixture.attachmentRoot, "personal");
    const otherDir = join(fixture.attachmentRoot, "other");
    await mkdir(accountDir, { recursive: true });
    await mkdir(otherDir, { recursive: true });
    await writeFile(join(accountDir, "file.txt"), "one", "utf8");
    await writeFile(join(otherDir, "file.txt"), "two", "utf8");

    const result = await runCliWithCapture([
      "cache",
      "prune",
      "--config",
      fixture.configPath,
      "--account",
      "personal",
    ]);

    expect(result.exitCode).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({
      prunedPaths: [accountDir],
    });
    await expect(readFile(join(otherDir, "file.txt"), "utf8")).resolves.toBe(
      "two",
    );
  });

  test("rejects combining --all with --account", async () => {
    const fixture = await useFixture();

    const result = await runCliWithCapture([
      "cache",
      "prune",
      "--config",
      fixture.configPath,
      "--all",
      "--account",
      "personal",
    ]);

    expect(result.exitCode).toBe(2);
    expect(JSON.parse(result.stderr)).toMatchObject({
      error: {
        code: "INVALID_ARGUMENT",
        message: "cache prune accepts either --all or --account, but not both",
      },
    });
  });
});
