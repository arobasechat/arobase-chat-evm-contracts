import { startChains } from "./chains.ts";
import { deployLocal } from "./deploy-local.ts";
import { startBundler } from "./lib/bundler.ts";
import { startLocalRelay } from "./lib/local-relay.ts";

await startChains();
await deployLocal();
startBundler("http://127.0.0.1:8545", 4337, 0);
startBundler("http://127.0.0.1:8546", 4338, 1);
startBundler("http://127.0.0.1:8547", 4339, 2);
console.log("Bundlers ERC-4337 (Alto) → http://127.0.0.1:4337 (social), :4338 (contenu), :4339 (ancrage)");
if (!process.argv.includes("--no-seed")) await import("./seed.ts");
if (!process.argv.includes("--no-relay")) await startLocalRelay();
console.log("\nLocal stack ready. Start the front with: cd ../arobase-chat-front && pnpm dev");
console.log("Ctrl+C to stop the chains.");
