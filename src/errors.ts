export type ExitCode = 0 | 1 | 2 | 3 | 4 | 5 | 6;

export const EXIT_CODES = {
  success: 0,
  generalError: 1,
  invalidCliUsage: 2,
  configurationError: 3,
  authenticationBootstrapError: 4,
  graphqlExecutionError: 5,
  providerApiError: 6,
} as const satisfies Record<string, ExitCode>;

export type AppErrorCode =
  | "ACCOUNT_NOT_FOUND"
  | "ATTACHMENT_NOT_FOUND"
  | "AUTH_BOOTSTRAP_NOT_IMPLEMENTED"
  | "AUTH_REQUIRED"
  | "CONFIG_INVALID"
  | "CREDENTIAL_NOT_FOUND"
  | "INVALID_ARGUMENT"
  | "MESSAGE_NOT_FOUND"
  | "PROVIDER_RATE_LIMITED"
  | "SEND_DISABLED_IN_READER"
  | "SEND_NOT_SUPPORTED";

export class AppError extends Error {
  readonly code: AppErrorCode;
  readonly exitCode: ExitCode;
  readonly details: Readonly<Record<string, unknown>> | undefined;

  constructor(
    message: string,
    code: AppErrorCode,
    exitCode: ExitCode,
    details?: Readonly<Record<string, unknown>>,
  ) {
    super(message);
    this.name = "AppError";
    this.code = code;
    this.exitCode = exitCode;
    this.details = details;
  }
}

export function isAppError(error: unknown): error is AppError {
  return error instanceof AppError;
}

export function toAppError(error: unknown): AppError {
  if (isAppError(error)) {
    return error;
  }

  if (error instanceof Error) {
    return new AppError(
      error.message,
      "CONFIG_INVALID",
      EXIT_CODES.generalError,
    );
  }

  return new AppError(
    "Unexpected error",
    "CONFIG_INVALID",
    EXIT_CODES.generalError,
  );
}
