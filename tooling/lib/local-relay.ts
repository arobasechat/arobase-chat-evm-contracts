import { execFileSync, spawn } from "node:child_process";
import { readFileSync, rmSync } from "node:fs";
import { resolve } from "node:path";
import { hasRelay, RELAY_DIR, TOOLING_DIR } from "./paths.ts";

const RELAY_PK = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a";

export async function startLocalRelay() {
  if (!hasRelay()) {
    console.log(`Relais push non démarré : clonez arobase-chat-push-relay à côté (${RELAY_DIR}) et lancez-y « pnpm install ».`);
    return;
  }
  const deployments = JSON.parse(readFileSync(resolve(TOOLING_DIR, "deployments.local.json"), "utf8"));
  const data = resolve(RELAY_DIR, "data", "local.json");
  rmSync(data, { force: true });
  const env = {
    ...process.env,
    REGISTRY: deployments.social.registry,
    REGISTRY_RPC: "http://127.0.0.1:8545",
    RELAY_PK,
    RELAY_TICK_MS: "3000",
    RELAY_ALLOW_HTTP: "1",
  };
  const tsx = resolve(RELAY_DIR, "node_modules/.bin/tsx");
  const relay = resolve(RELAY_DIR, "src/relay.ts");
  const args = ["--network", "local", "--data", data];
  execFileSync(tsx, [relay, "init", ...args, "--contact", "mailto:dev@localhost"], { env, stdio: "ignore", cwd: RELAY_DIR });
  execFileSync(tsx, [relay, "register", ...args, "--name", "Relais local", "--info", "Instance de développement"], { env, stdio: "inherit", cwd: RELAY_DIR });
  const proc = spawn(tsx, [relay, "run", ...args], { env, stdio: ["ignore", "inherit", "inherit"], cwd: RELAY_DIR });
  process.on("exit", () => proc.kill("SIGINT"));
  console.log(`Relais push local démarré (${data}).`);
}
