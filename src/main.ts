/**
 * mail-gateway - Main entry point
 *
 * mailer
 */

import { greet } from "./lib";

function main(): void {
  const message = greet("World");
  console.log(message);
}

main();
