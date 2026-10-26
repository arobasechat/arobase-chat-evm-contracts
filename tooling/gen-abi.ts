import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { CONTRACT_DIR, FRONT_DIR, hasFront, hasRelay, RELAY_DIR, TOOLING_DIR } from "./lib/paths.ts";

const CONTRACTS = ["Content", "Social", "Registry", "Stake", "Inbox", "Multicall3", "Paymaster", "Names", "PushRelays", "Media", "Vault"] as const;

execFileSync("forge", ["build"], { cwd: CONTRACT_DIR, stdio: "inherit" });

const artifact = (name: string, file = `${name}.sol`) => JSON.parse(readFileSync(resolve(CONTRACT_DIR, "out", file, `${name}.json`), "utf8"));
const timelock = artifact("TimelockController");

mkdirSync(resolve(CONTRACT_DIR, "abi"), { recursive: true });
for (const name of [...CONTRACTS, "TimelockController"]) {
  writeFileSync(resolve(CONTRACT_DIR, "abi", `${name}.json`), JSON.stringify(artifact(name).abi, null, 2) + "\n");
}

let abiSource = "";
for (const name of CONTRACTS) {
  abiSource += `export const ${name[0].toLowerCase()}${name.slice(1)}Abi = ${JSON.stringify(artifact(name).abi, null, 2)} as const;\n\n`;
}

writeFileSync(
  resolve(TOOLING_DIR, "lib/abi.ts"),
  abiSource +
    `export const timelockAbi = ${JSON.stringify(timelock.abi, null, 2)} as const;\n\n` +
    `export const multicall3Runtime = ${JSON.stringify(artifact("Multicall3").deployedBytecode.object)} as const;\n`,
);
console.log("✓ abi/*.json et tooling/lib/abi.ts");

if (hasFront()) {
  mkdirSync(resolve(FRONT_DIR, "src/abi"), { recursive: true });
  writeFileSync(resolve(FRONT_DIR, "src/abi/index.ts"), abiSource);
  console.log(`✓ ${resolve(FRONT_DIR, "src/abi/index.ts")}`);
}
if (hasRelay()) {
  writeFileSync(resolve(RELAY_DIR, "src/abi.ts"), abiSource);
  console.log(`✓ ${resolve(RELAY_DIR, "src/abi.ts")}`);
}
