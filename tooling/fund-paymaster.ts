import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createPublicClient, createWalletClient, defineChain, fallback, formatEther, http, parseEther, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { TOOLING_DIR } from "./lib/paths.ts";
import { ENTRYPOINT_V08 } from "./lib/aa.ts";
import { withLocalRpcs } from "./lib/rpcs.ts";

const [, , chainIdArg, amount, networkName = "mainnet"] = process.argv;
if (!chainIdArg || !amount) {
  console.log("Usage : pnpm fund-paymaster <chainId> <montant> [network]   (clé : FUNDER_PK ou DEPLOYER_PK)");
  process.exit(1);
}
const pk = (process.env.FUNDER_PK ?? process.env.DEPLOYER_PK) as Hex | undefined;
if (!pk) throw new Error("FUNDER_PK (ou DEPLOYER_PK) requis");
const state = JSON.parse(readFileSync(resolve(TOOLING_DIR, `deployments.${networkName}.json`), "utf8"));
const pm = state.paymasters?.[chainIdArg];
if (!pm) throw new Error(`Aucun paymaster pour la chain ${chainIdArg}`);
const rpcs = networkName === "local" ? ["http://127.0.0.1:8545"] : withLocalRpcs(chainIdArg, state.rpcs?.[chainIdArg] ?? []);
const chain = defineChain({ id: Number(chainIdArg), name: chainIdArg, nativeCurrency: { name: "Gas", symbol: "GAS", decimals: 18 }, rpcUrls: { default: { http: rpcs } } });
const transport = fallback(rpcs.map((u) => http(u)));
const pub = createPublicClient({ chain, transport });
const wallet = createWalletClient({ account: privateKeyToAccount(pk), chain, transport });
const abi = [
  { type: "function", name: "depositTo", inputs: [{ type: "address" }], outputs: [], stateMutability: "payable" },
  { type: "function", name: "balanceOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
] as const;
const hash = await wallet.writeContract({ address: ENTRYPOINT_V08, abi, functionName: "depositTo", args: [pm.paymaster as Address], value: parseEther(amount) });
await pub.waitForTransactionReceipt({ hash });
const balance = await pub.readContract({ address: ENTRYPOINT_V08, abi, functionName: "balanceOf", args: [pm.paymaster] });
console.log(`✓ Dépôt du paymaster ${pm.paymaster} sur ${chainIdArg} : ${formatEther(balance)}`);
