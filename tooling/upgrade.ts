import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createPublicClient, createWalletClient, defineChain, encodeAbiParameters, encodeFunctionData, fallback, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { loadState } from "./lib/deploy.ts";
import { DEPLOYER_PK as LOCAL_PK } from "./lib/local.ts";
import { CONTRACT_DIR, TOOLING_DIR } from "./lib/paths.ts";
import { withLocalRpcs } from "./lib/rpcs.ts";
import { viaTimelock } from "./lib/timelock.ts";

const args = process.argv.slice(2);
const option = (name: string) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
};
const name = args.find((a, i) => !a.startsWith("--") && !args[i - 1]?.startsWith("--"));
const networkName = option("network") ?? "mainnet";
const only = option("chain");
const SOCIAL = ["Registry", "Social", "Names", "PushRelays", "Media", "Vault"];
const CONTENT = ["Content", "Inbox"];
if (!name || ![...SOCIAL, ...CONTENT, "Paymaster"].includes(name)) {
  console.log(`Usage : DEPLOYER_PK=… pnpm upgrade-contract <${[...SOCIAL, ...CONTENT, "Paymaster"].join("|")}> [--chain <id>] [--network mainnet|local]`);
  process.exit(1);
}
const pk = (process.env.DEPLOYER_PK ?? (networkName === "local" ? LOCAL_PK : undefined)) as Hex | undefined;
if (!pk) throw new Error("DEPLOYER_PK requis (proposer du timelock)");
const account = privateKeyToAccount(pk);
const state = loadState(resolve(TOOLING_DIR, `deployments.${networkName}.json`));
const s = state.social!;
const key = name[0].toLowerCase() + name.slice(1);

const targets: { chainId: number; proxy: Address; timelock: Address; entryPoint?: Address }[] = [];
if (name === "Paymaster") {
  for (const p of Object.values(state.paymasters)) targets.push({ chainId: p.chainId, proxy: p.paymaster, timelock: p.timelock, entryPoint: p.entryPoint });
} else if (SOCIAL.includes(name)) {
  targets.push({ chainId: s.chainId, proxy: (s as unknown as Record<string, Address>)[key], timelock: s.timelock });
} else {
  for (const c of Object.values(state.contents)) targets.push({ chainId: c.chainId, proxy: (c as unknown as Record<string, Address>)[key], timelock: c.timelock });
}

const upgradeAbi = [
  { type: "function", name: "upgradeToAndCall", inputs: [{ type: "address" }, { type: "bytes" }], outputs: [], stateMutability: "payable" },
  { type: "function", name: "implementation", inputs: [], outputs: [{ type: "address" }], stateMutability: "view" },
] as const;

for (const t of targets.filter((x) => !only || String(x.chainId) === only)) {
  const rpcs = withLocalRpcs(t.chainId, state.rpcs[t.chainId] ?? []);
  const chain = defineChain({ id: t.chainId, name: String(t.chainId), nativeCurrency: { name: "Gas", symbol: "GAS", decimals: 18 }, rpcUrls: { default: { http: rpcs } } });
  const transport = fallback(rpcs.map((u) => http(u, { timeout: 60_000, retryCount: 2 })));
  const pub = createPublicClient({ chain, transport });
  const wallet = createWalletClient({ account, chain, transport });
  const before = await pub.readContract({ address: t.proxy, abi: upgradeAbi, functionName: "implementation" });
  console.log(`\n▶ ${name} sur ${t.chainId} (proxy ${t.proxy}, implémentation actuelle ${before})`);
  mkdirSync(resolve(CONTRACT_DIR, "deployments"), { recursive: true });
  execFileSync("forge", ["script", "script/Upgrade.s.sol:Upgrade", "--rpc-url", rpcs[0], "--broadcast", "--slow", "-q"], {
    cwd: CONTRACT_DIR,
    stdio: "inherit",
    env: {
      ...process.env,
      DEPLOYER_PK: pk,
      ARTIFACT: `${name}.sol:${name}`,
      ...(t.entryPoint ? { CONSTRUCTOR_ARGS: encodeAbiParameters([{ type: "address" }], [t.entryPoint]) } : {}),
    },
  });
  const impl = JSON.parse(readFileSync(resolve(CONTRACT_DIR, "deployments", `upgrade-${t.chainId}.json`), "utf8")).implementation as Address;
  const data = encodeFunctionData({ abi: upgradeAbi, functionName: "upgradeToAndCall", args: [impl, "0x"] });
  const r = await viaTimelock(pub as never, wallet, t.timelock, t.proxy, data, `upgrade ${name} ${t.chainId}`);
  if (r.executed) {
    const after = await pub.readContract({ address: t.proxy, abi: upgradeAbi, functionName: "implementation" });
    console.log(`   ✓ ${name} mis à jour : ${after} (adresse et données inchangées)`);
  }
}
