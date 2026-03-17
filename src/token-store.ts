import { access, readFile, rm } from "node:fs/promises";
import { constants as fsConstants } from "node:fs";

import type { AccessMode, AuthState } from "./domain";
import type { CredentialConfig } from "./config";
import { AppError, EXIT_CODES } from "./errors";
import { isRecord } from "./records";

interface ParsedTokenStore {
  readonly accessMode: AccessMode | null;
  readonly expiresAt: string | null;
  readonly hasRefreshToken: boolean;
}

function readAccessMode(value: unknown): AccessMode | null {
  if (value === "read" || value === "read_send") {
    return value;
  }
  return null;
}

function parseTokenStore(source: string): ParsedTokenStore {
  const parsed = JSON.parse(source) as unknown;
  if (!isRecord(parsed)) {
    return {
      accessMode: null,
      expiresAt: null,
      hasRefreshToken: false,
    };
  }

  const refreshToken = parsed["refreshToken"];
  const hasRefreshToken =
    typeof refreshToken === "string" && refreshToken.length > 0;
  const parsedExpiresAt = parsed["expiresAt"];
  const expiresAt =
    typeof parsedExpiresAt === "string" && parsedExpiresAt.length > 0
      ? parsedExpiresAt
      : null;

  return {
    accessMode: readAccessMode(parsed["accessMode"]),
    expiresAt,
    hasRefreshToken,
  };
}

export interface TokenInspectionResult {
  readonly state: AuthState;
  readonly exists: boolean;
  readonly grantedAccessMode: AccessMode | null;
  readonly expiresAt: string | null;
  readonly hasRefreshToken: boolean;
}

const INVALID_TOKEN_RESULT = {
  state: "INVALID",
  exists: true,
  grantedAccessMode: null,
  expiresAt: null,
  hasRefreshToken: false,
} as const satisfies TokenInspectionResult;

export async function inspectTokenStore(
  credential: CredentialConfig,
): Promise<TokenInspectionResult> {
  try {
    await access(credential.tokenStorePath, fsConstants.R_OK);
  } catch {
    return {
      state: "MISSING",
      exists: false,
      grantedAccessMode: null,
      expiresAt: null,
      hasRefreshToken: false,
    };
  }

  const source = await readFile(credential.tokenStorePath, "utf8").catch(() => {
    return null;
  });

  if (source === null) {
    return INVALID_TOKEN_RESULT;
  }

  try {
    const parsed = parseTokenStore(source);
    if (
      parsed.accessMode !== null &&
      parsed.accessMode !== credential.accessMode
    ) {
      return {
        state: "SCOPE_MISMATCH",
        exists: true,
        grantedAccessMode: parsed.accessMode,
        expiresAt: parsed.expiresAt,
        hasRefreshToken: parsed.hasRefreshToken,
      };
    }

    if (parsed.expiresAt !== null) {
      const expiresAtEpoch = Date.parse(parsed.expiresAt);
      if (Number.isNaN(expiresAtEpoch)) {
        return {
          state: "INVALID",
          exists: true,
          grantedAccessMode: parsed.accessMode,
          expiresAt: parsed.expiresAt,
          hasRefreshToken: parsed.hasRefreshToken,
        };
      }

      if (expiresAtEpoch <= Date.now() && !parsed.hasRefreshToken) {
        return {
          state: "EXPIRED",
          exists: true,
          grantedAccessMode: parsed.accessMode,
          expiresAt: parsed.expiresAt,
          hasRefreshToken: parsed.hasRefreshToken,
        };
      }
    }

    return {
      state: parsed.accessMode === null ? "UNKNOWN" : "READY",
      exists: true,
      grantedAccessMode: parsed.accessMode,
      expiresAt: parsed.expiresAt,
      hasRefreshToken: parsed.hasRefreshToken,
    };
  } catch {
    return INVALID_TOKEN_RESULT;
  }
}

export async function revokeTokenStore(
  credential: CredentialConfig,
): Promise<boolean> {
  try {
    await access(credential.tokenStorePath, fsConstants.F_OK);
  } catch {
    return false;
  }

  try {
    await rm(credential.tokenStorePath, { force: false });
    return true;
  } catch (error: unknown) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") {
      return false;
    }
    throw new AppError(
      `Failed to revoke token store for credential ${credential.id}`,
      "AUTH_REQUIRED",
      EXIT_CODES.authenticationBootstrapError,
      { cause: error instanceof Error ? error.message : String(error) },
    );
  }
}
