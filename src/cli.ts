import { readFile } from "node:fs/promises";

import { loadConfig, validateConfig } from "./config";
import { executeReaderGraphql } from "./graphql";
import { AppError, EXIT_CODES, toAppError } from "./errors";
import type { ExitCode } from "./errors";
import { MailGatewayReaderService } from "./service";

type Writer = Pick<NodeJS.WriteStream, "write">;

const BOOLEAN_FLAGS = new Set(["all", "pretty"]);

export interface RunCliOptions {
  readonly stdout?: Writer;
  readonly stderr?: Writer;
  readonly env?: NodeJS.ProcessEnv;
}

interface ParsedArguments {
  readonly positionals: readonly string[];
  readonly flags: ReadonlyMap<string, string | boolean>;
}

function parseArguments(argv: readonly string[]): ParsedArguments {
  const positionals: string[] = [];
  const flags = new Map<string, string | boolean>();

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === undefined) {
      continue;
    }

    if (!token.startsWith("--")) {
      positionals.push(token);
      continue;
    }

    const flagBody = token.slice(2);
    const equalsIndex = flagBody.indexOf("=");
    const rawKey = equalsIndex >= 0 ? flagBody.slice(0, equalsIndex) : flagBody;
    const inlineValue =
      equalsIndex >= 0 ? flagBody.slice(equalsIndex + 1) : undefined;
    if (rawKey.length === 0) {
      throw new AppError(
        "Invalid empty flag",
        "INVALID_ARGUMENT",
        EXIT_CODES.invalidCliUsage,
      );
    }

    if (inlineValue !== undefined) {
      flags.set(rawKey, inlineValue);
      continue;
    }

    const nextToken = argv[index + 1];
    if (
      BOOLEAN_FLAGS.has(rawKey) &&
      (nextToken === undefined ||
        (nextToken !== "true" && nextToken !== "false"))
    ) {
      flags.set(rawKey, true);
      continue;
    }

    if (nextToken !== undefined && !nextToken.startsWith("--")) {
      flags.set(rawKey, nextToken);
      index += 1;
      continue;
    }

    flags.set(rawKey, true);
  }

  return {
    positionals,
    flags,
  };
}

function getStringFlag(
  flags: ReadonlyMap<string, string | boolean>,
  name: string,
): string | undefined {
  const value = flags.get(name);
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "string") {
    throw new AppError(
      `--${name} requires a value`,
      "INVALID_ARGUMENT",
      EXIT_CODES.invalidCliUsage,
    );
  }
  return value;
}

function getBooleanFlag(
  flags: ReadonlyMap<string, string | boolean>,
  name: string,
): boolean {
  const value = flags.get(name);
  if (value === undefined) {
    return false;
  }
  if (typeof value === "string") {
    if (value === "true") {
      return true;
    }
    if (value === "false") {
      return false;
    }
    throw new AppError(
      `--${name} accepts only true or false when given a value`,
      "INVALID_ARGUMENT",
      EXIT_CODES.invalidCliUsage,
    );
  }
  return value;
}

async function readJsonFile(path: string): Promise<Record<string, unknown>> {
  const source = await readFile(path, "utf8").catch((error: unknown) => {
    throw new AppError(
      `Failed to read JSON variables file: ${path}`,
      "INVALID_ARGUMENT",
      EXIT_CODES.invalidCliUsage,
      { cause: error instanceof Error ? error.message : String(error) },
    );
  });

  return parseJsonObject(source, {
    invalidJsonMessage: `Failed to parse JSON variables file: ${path}`,
    invalidObjectMessage: `JSON variables file must contain an object: ${path}`,
  });
}

function parseJsonObject(
  source: string,
  messages: {
    readonly invalidJsonMessage: string;
    readonly invalidObjectMessage: string;
  },
): Record<string, unknown> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(source) as unknown;
  } catch (error: unknown) {
    throw new AppError(
      messages.invalidJsonMessage,
      "INVALID_ARGUMENT",
      EXIT_CODES.invalidCliUsage,
      { cause: error instanceof Error ? error.message : String(error) },
    );
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new AppError(
      messages.invalidObjectMessage,
      "INVALID_ARGUMENT",
      EXIT_CODES.invalidCliUsage,
    );
  }

  return parsed as Record<string, unknown>;
}

async function loadQuery(
  flags: ReadonlyMap<string, string | boolean>,
): Promise<string> {
  const inlineQuery = getStringFlag(flags, "query");
  const queryFile = getStringFlag(flags, "query-file");
  if ((inlineQuery === undefined) === (queryFile === undefined)) {
    throw new AppError(
      "Exactly one of --query or --query-file is required",
      "INVALID_ARGUMENT",
      EXIT_CODES.invalidCliUsage,
    );
  }

  if (inlineQuery !== undefined) {
    return inlineQuery;
  }

  if (queryFile === undefined) {
    throw new AppError(
      "Missing --query-file value",
      "INVALID_ARGUMENT",
      EXIT_CODES.invalidCliUsage,
    );
  }

  return readFile(queryFile, "utf8").catch((error: unknown) => {
    throw new AppError(
      `Failed to read GraphQL query file: ${queryFile}`,
      "INVALID_ARGUMENT",
      EXIT_CODES.invalidCliUsage,
      { cause: error instanceof Error ? error.message : String(error) },
    );
  });
}

async function loadVariables(
  flags: ReadonlyMap<string, string | boolean>,
): Promise<Record<string, unknown>> {
  const inlineVariables = getStringFlag(flags, "variables");
  const variablesFile = getStringFlag(flags, "variables-file");
  if (inlineVariables !== undefined && variablesFile !== undefined) {
    throw new AppError(
      "Use only one of --variables or --variables-file",
      "INVALID_ARGUMENT",
      EXIT_CODES.invalidCliUsage,
    );
  }

  if (inlineVariables !== undefined) {
    return parseJsonObject(inlineVariables, {
      invalidJsonMessage: "--variables must be valid JSON",
      invalidObjectMessage: "--variables must be a JSON object",
    });
  }

  if (variablesFile !== undefined) {
    return readJsonFile(variablesFile);
  }

  return {};
}

function writeJson(writer: Writer, value: unknown, pretty: boolean): void {
  writer.write(`${JSON.stringify(value, null, pretty ? 2 : undefined)}\n`);
}

function formatErrorForOutput(error: AppError): Record<string, unknown> {
  return {
    error: {
      message: error.message,
      code: error.code,
      exitCode: error.exitCode,
      ...(error.details === undefined ? {} : { details: error.details }),
    },
  };
}

async function loadService(
  configPath: string | undefined,
  env: NodeJS.ProcessEnv,
): Promise<MailGatewayReaderService> {
  return new MailGatewayReaderService(await loadConfig(configPath, env));
}

export async function runCli(
  argv: readonly string[],
  options: RunCliOptions = {},
): Promise<ExitCode> {
  const stdout = options.stdout ?? process.stdout;
  const stderr = options.stderr ?? process.stderr;
  const env = options.env ?? process.env;

  try {
    const parsed = parseArguments(argv);
    const [command, subcommand] = parsed.positionals;
    const configPath =
      getStringFlag(parsed.flags, "config") ?? env["MAIL_GATEWAY_CONFIG"];
    const pretty = getBooleanFlag(parsed.flags, "pretty");

    switch (command) {
      case "graphql": {
        const config = await loadConfig(configPath, env);
        const query = await loadQuery(parsed.flags);
        const variables = await loadVariables(parsed.flags);
        const result = await executeReaderGraphql({
          config,
          query,
          variables,
        });
        writeJson(stdout, result.body, pretty);
        return result.exitCode;
      }
      case "config": {
        if (subcommand !== "validate") {
          throw new AppError(
            "config requires the validate subcommand",
            "INVALID_ARGUMENT",
            EXIT_CODES.invalidCliUsage,
          );
        }
        const result = await validateConfig(configPath, env);
        writeJson(stdout, result, pretty);
        return EXIT_CODES.success;
      }
      case "auth": {
        const credentialId = getStringFlag(parsed.flags, "credential");
        if (credentialId === undefined) {
          throw new AppError(
            "auth commands require --credential",
            "INVALID_ARGUMENT",
            EXIT_CODES.invalidCliUsage,
          );
        }

        const service = await loadService(configPath, env);
        switch (subcommand) {
          case "status": {
            const result = await service.getAuthStatus(credentialId);
            writeJson(stdout, result, pretty);
            return EXIT_CODES.success;
          }
          case "revoke": {
            const result = await service.revokeAuth(credentialId);
            writeJson(
              stdout,
              {
                credentialId,
                ...result,
              },
              pretty,
            );
            return EXIT_CODES.success;
          }
          case "login": {
            await service.login(credentialId);
            return EXIT_CODES.success;
          }
          default:
            throw new AppError(
              "auth requires one of: login, revoke, status",
              "INVALID_ARGUMENT",
              EXIT_CODES.invalidCliUsage,
            );
        }
      }
      case "cache": {
        if (subcommand !== "prune") {
          throw new AppError(
            "cache requires the prune subcommand",
            "INVALID_ARGUMENT",
            EXIT_CODES.invalidCliUsage,
          );
        }
        const service = await loadService(configPath, env);
        const accountId = getStringFlag(parsed.flags, "account") ?? null;
        const all = getBooleanFlag(parsed.flags, "all");
        const result = await service.pruneCache({ accountId, all });
        writeJson(stdout, result, pretty);
        return EXIT_CODES.success;
      }
      default:
        throw new AppError(
          "Supported commands: graphql, config validate, auth <login|revoke|status>, cache prune",
          "INVALID_ARGUMENT",
          EXIT_CODES.invalidCliUsage,
        );
    }
  } catch (error: unknown) {
    const appError = toAppError(error);
    writeJson(stderr, formatErrorForOutput(appError), true);
    return appError.exitCode;
  }
}
