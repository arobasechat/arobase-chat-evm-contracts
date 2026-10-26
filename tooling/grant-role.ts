import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createPublicClient, createWalletClient, defineChain, fallback, http, isAddress, parseGwei, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { socialAbi } from "./lib/abi.ts";
import { TOOLING_DIR } from "./lib/paths.ts";
import { withLocalRpcs } from "./lib/rpcs.ts";
import { addressTarget, KIND, signAction } from "./lib/protocol.ts";

const [target, roleArg, networkName = "mainnet"] = process.argv.slice(2);
const ROLES: Record<string, number> = { user: 0, utilisateur: 0, moderateur: 1, moderator: 1, admin: 2, "0": 0, "1": 1, "2": 2 };
const role = ROLES[(roleArg ?? "").toLowerCase()];
if (!target || !isAddress(target) || role === undefined)
  throw new Error("Usage : pnpm grant-role <adresse> <admin|moderateur|utilisateur> [mainnet|local]");
const pk = process.env.DEPLOYER_PK as Hex | undefined;
if (!pk) throw new Error("DEPLOYER_PK requis (clé d'un compte admin)");
const admin = privateKeyToAccount(pk);

const state = JSON.parse(readFileSync(resolve(TOOLING_DIR, `deployments.${networkName}.json`), "utf8"));
const net = networkName === "local" ? undefined : JSON.parse(readFileSync(resolve(TOOLING_DIR, `networks.${networkName}.json`), "utf8"));
const spec = net?.social ?? { chainId: 31337, name: "Local" };
const rpcs: string[] = net ? withLocalRpcs(spec.chainId, state.rpcs[spec.chainId]) : ["http://127.0.0.1:8545"];
const chain = defineChain({
  id: spec.chainId,
  name: spec.name,
  nativeCurrency: { name: "Gas", symbol: "GAS", decimals: 18 },
  rpcUrls: { default: { http: rpcs } },
  ...(spec.priorityGwei
    ? { fees: { estimateFeesPerGas: async () => ({ maxPriorityFeePerGas: parseGwei(spec.priorityGwei), maxFeePerGas: parseGwei(spec.maxFeeGwei ?? "2") }) } }
    : {}),
});
const transport = fallback(rpcs.map((u) => http(u, { timeout: 60_000, retryCount: 2 })));
const pub = createPublicClient({ chain, transport });
const wallet = createWalletClient({ account: admin, chain, transport });
const social = state.social.social as Address;

const [myRole, current, nonce] = await Promise.all([
  pub.readContract({ address: social, abi: socialAbi, functionName: "role", args: [admin.address] }),
  pub.readContract({ address: social, abi: socialAbi, functionName: "role", args: [target] }),
  pub.readContract({ address: social, abi: socialAbi, functionName: "nonces", args: [admin.address] }),
]);
if (myRole !== 2) throw new Error(`${admin.address} n'est pas admin sur ${spec.name}.`);
const names = ["utilisateur", "modérateur", "admin"];
if (current === role) {
  console.log(`${target} est déjà ${names[role]}.`);
  process.exit(0);
}
const action = await signAction(admin, KIND.ROLE, addressTarget(target), role, nonce);
const hash = await wallet.writeContract({ address: social, abi: socialAbi, functionName: "submit", args: [action] });
const receipt = await pub.waitForTransactionReceipt({ hash });
const after = await pub.readContract({ address: social, abi: socialAbi, functionName: "role", args: [target] });
if (receipt.status !== "success" || after !== role) throw new Error(`Action refusée (tx ${hash}).`);
console.log(`✓ ${target} : ${names[current]} → ${names[role]} (tx ${hash})`);
