export {
  getCredentialPathEnvVarName,
  loadConfig,
  resolveDefaultConfigPath,
  validateConfig,
} from "./config";
export type {
  AccountConfig,
  CredentialConfig,
  CredentialPathKey,
  MailGatewayConfig,
  StorageConfig,
} from "./config";
export type {
  AccessMode,
  AuthState,
  AuthStatusReport,
  MailAccount,
  MailAttachment,
  MailCapabilities,
  MailMessage,
  MailProvider,
  MailThread,
  ThreadConnection,
  ThreadSearchInput,
} from "./domain";
export { AppError, EXIT_CODES } from "./errors";
export { executeReaderGraphql } from "./graphql";
export { runCli } from "./cli";
export { MailGatewayReaderService } from "./service";
