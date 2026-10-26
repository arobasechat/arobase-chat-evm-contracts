import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createPublicClient, createWalletClient, defineChain, encodeFunctionData, fallback, formatEther, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { TOOLING_DIR } from "./lib/paths.ts";
import { withLocalRpcs } from "./lib/rpcs.ts";
import { viaTimelock } from "./lib/timelock.ts";

const file = process.argv[2] ?? "deployments.legacy-dechat.mainnet.json";
const pk = process.env.DEPLOYER_PK as Hex | undefined;
if (!pk) throw new Error("DEPLOYER_PK requis");
const account = privateKeyToAccount(pk);
const legacy = JSON.parse(readFileSync(resolve(TOOLING_DIR, file), "utf8"));

type Pm = { chainId: number; entryPoint: Address; paymaster: Address; timelock: Address };
const all: Pm[] = [...Object.values((legacy.paymasters ?? {}) as Record<string, Pm>), ...Object.values((legacy.paymastersOld ?? {}) as Record<string, Pm>)];
const unique = [...new Map(all.map((p) => [`${p.chainId}:${p.paymaster.toLowerCase()}`, p])).values()];

const epAbi = [
  { type: "function", name: "balanceOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  {
    type: "function",
    name: "getDepositInfo",
    inputs: [{ type: "address" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "deposit", type: "uint256" },
          { name: "staked", type: "bool" },
          { name: "stake", type: "uint112" },
          { name: "unstakeDelaySec", type: "uint32" },
          { name: "withdrawTime", type: "uint48" },
        ],
      },
    ],
    stateMutability: "view",
  },
] as const;
const pmAbi = [
  { type: "function", name: "withdrawTo", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "unlockStake", inputs: [], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "withdrawStake", inputs: [{ type: "address" }], outputs: [], stateMutability: "nonpayable" },
] as const;

const pending: string[] = [];
for (const p of unique) {
  const rpcs = withLocalRpcs(p.chainId, legacy.rpcs?.[p.chainId] ?? []);
  const chain = defineChain({ id: p.chainId, name: String(p.chainId), nativeCurrency: { name: "Gas", symbol: "GAS", decimals: 18 }, rpcUrls: { default: { http: rpcs } } });
  const transport = fallback(rpcs.map((u) => http(u, { timeout: 60_000, retryCount: 2 })));
  const pub = createPublicClient({ chain, transport });
  const wallet = createWalletClient({ account, chain, transport });
  const via = (data: Hex, label: string) => viaTimelock(pub as never, wallet, p.timelock, p.paymaster, data, label);
  const info = await pub.readContract({ address: p.entryPoint, abi: epAbi, functionName: "getDepositInfo", args: [p.paymaster] });
  console.log(`\n${p.chainId} · ${p.paymaster} : dépôt ${formatEther(info.deposit)}, stake ${formatEther(info.stake)}${info.staked ? " (verrouillé)" : ""}`);
  if (info.deposit > 0n) {
    await via(encodeFunctionData({ abi: pmAbi, functionName: "withdrawTo", args: [account.address, info.deposit] }), `retrait du dépôt ${p.chainId}`);
  }
  if (info.stake === 0n) continue;
  if (info.staked) {
    await via(encodeFunctionData({ abi: pmAbi, functionName: "unlockStake" }), `déverrouillage du stake ${p.chainId}`);
    pending.push(`${p.chainId} ${p.paymaster} : stake de ${formatEther(info.stake)} récupérable après ${info.unstakeDelaySec} s`);
  } else if (info.withdrawTime * 1000 <= Date.now()) {
    await via(encodeFunctionData({ abi: pmAbi, functionName: "withdrawStake", args: [account.address] }), `récupération du stake ${p.chainId}`);
  } else {
    pending.push(`${p.chainId} ${p.paymaster} : stake de ${formatEther(info.stake)} récupérable après le ${new Date(info.withdrawTime * 1000).toLocaleString("fr-FR")}`);
  }
}
console.log(pending.length ? `\nRelancez plus tard pour finir :\n  ${pending.join("\n  ")}` : "\n✓ Tous les fonds des anciens paymasters sont revenus sur votre clé.");
