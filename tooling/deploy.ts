import { resolve } from "node:path";
import { createInterface } from "node:readline/promises";
import { createPublicClient, defineChain, fallback, formatEther, http, parseEther, parseGwei, type Chain, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { rankRpcs } from "./lib/chainlist.ts";
import { configureRegistry, deployChain, loadState, publishInstance, recordDeployment, registryParams, saveState, type ChainPlan, type Role } from "./lib/deploy.ts";
import { TOOLING_DIR } from "./lib/paths.ts";
import { withLocalRpcs } from "./lib/rpcs.ts";
import { readFileSync } from "node:fs";

type ChainSpec = {
  chainId: number;
  name: string;
  role?: 1 | 2;
  legacy?: boolean;
  rpcs?: string[];
  ownRpcs?: string[];
  priorityGwei?: string;
  maxFeeGwei?: string;
};
type NetworkFile = {
  name: string;
  social: ChainSpec;
  content: ChainSpec[];
  timelock: { delaySeconds: number; proposer: string | null };
  initialAdmins: string[];
  stake: { minStake: string; stakeUnit: string; cooldownSeconds: number };
  rpcsPerChain: number;
  params: Record<string, unknown>;
  avoidRpcs?: string[];
  repoUrl?: string;
  sponsor?: {
    difficulty: number;
    unstakeDelaySeconds: number;
    chains: Record<
      string,
      {
        stake: string;
        deposit: string;
        maxCostPerOp: string;
        dailyBudget?: string;
        perSenderDaily?: number;
        bundlers: string[];
        limits?: {
          preVerificationGas?: number;
          preVerificationGasPerByte?: number;
          priorityFeeGwei?: string;
        };
      }
    >;
  };
};

const args = process.argv.slice(2);
const option = (name: string) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
};
const networkName = option("network") ?? "mainnet";
const net = JSON.parse(readFileSync(resolve(TOOLING_DIR, `networks.${networkName}.json`), "utf8")) as NetworkFile;
const statePath = resolve(TOOLING_DIR, `deployments.${networkName}.json`);
const state = loadState(statePath);
const save = () => saveState(statePath, state);

const pk = process.env.DEPLOYER_PK as Hex | undefined;
if (!pk || !/^0x[0-9a-fA-F]{64}$/.test(pk)) {
  console.error("DEPLOYER_PK manquant ou invalide. Exportez-le dans votre shell (jamais dans un fichier versionné).");
  process.exit(1);
}
const account = privateKeyToAccount(pk);

const GAS = { social: 30_000_000n, content: 12_000_000n };

const chainOf = (spec: ChainSpec, rpc: string): Chain =>
  defineChain({
    id: spec.chainId,
    name: spec.name,
    nativeCurrency: { name: "Gas", symbol: "GAS", decimals: 18 },
    rpcUrls: { default: { http: [rpc] } },
    ...(spec.priorityGwei
      ? {
          fees: {
            estimateFeesPerGas: async () => ({
              maxPriorityFeePerGas: parseGwei(spec.priorityGwei!),
              maxFeePerGas: parseGwei(spec.maxFeeGwei ?? String(Number(spec.priorityGwei) * 2)),
            }),
          },
        }
      : {}),
  });

const limitsEnv = (l: NonNullable<NonNullable<NetworkFile["sponsor"]>["chains"][string]["limits"]> = {}) => {
  const out: Record<string, string> = {};
  if (l.preVerificationGas) out.LIMIT_PRE_VERIFICATION_GAS = String(l.preVerificationGas);
  if (l.preVerificationGasPerByte) out.LIMIT_PRE_VERIFICATION_GAS_PER_BYTE = String(l.preVerificationGasPerByte);
  if (l.priorityFeeGwei) out.LIMIT_PRIORITY_FEE = parseGwei(l.priorityFeeGwei).toString();
  return out;
};

const sponsorEnv = (chainId: number): Record<string, string> | undefined => {
  const sp = net.sponsor;
  const c = sp?.chains[String(chainId)];
  if (!sp || !c) return undefined;
  return {
    POW_DIFFICULTY: String(sp.difficulty),
    MAX_COST_PER_OP: parseEther(c.maxCostPerOp).toString(),
    PAYMASTER_STAKE: parseEther(c.stake).toString(),
    PAYMASTER_UNSTAKE_DELAY: String(sp.unstakeDelaySeconds),
    PAYMASTER_DEPOSIT: parseEther(c.deposit).toString(),
    DAILY_BUDGET: parseEther(c.dailyBudget ?? "0").toString(),
    PER_SENDER_DAILY: String(c.perSenderDaily ?? 0),
    ...limitsEnv(c.limits),
  };
};

async function firstHealthy(urls: string[]) {
  for (const u of urls) {
    const ok = await createPublicClient({ transport: http(u, { timeout: 8_000, retryCount: 0 }) })
      .getBalance({ address: account.address })
      .then(() => true, () => false);
    if (ok) return u;
  }
  return urls[0];
}

async function plan(spec: ChainSpec, role: Role): Promise<ChainPlan & { balance: bigint; cost: bigint; own: { url: string; ok: boolean }[] }> {
  const avoid = net.avoidRpcs ?? [];
  const own = spec.ownRpcs ?? [];
  const ranked = (await rankRpcs(spec.chainId, [...own, ...(spec.rpcs ?? [])])).filter((r) => !avoid.some((a) => r.url.includes(a)));
  const reachable = new Set(ranked.map((r) => r.url));
  const publicRpcs = ranked.filter((r) => !own.includes(r.url) && r.cors).slice(0, net.rpcsPerChain).map((r) => r.url);
  const rpcs = [...own, ...publicRpcs];
  const txRpcs = withLocalRpcs(spec.chainId, [...own.filter((u) => reachable.has(u)), ...ranked.map((r) => r.url)]);
  if (!txRpcs.length) throw new Error(`Aucun RPC fonctionnel pour ${spec.name}`);
  const pub = createPublicClient({ transport: fallback(txRpcs.slice(0, 4).map((u) => http(u, { timeout: 15_000, retryCount: 1 }))) });
  const [balance, gasPrice] = await Promise.all([pub.getBalance({ address: account.address }), pub.getGasPrice()]);
  const rpc = await firstHealthy(txRpcs);
  const sponsor = sponsorEnv(spec.chainId);
  const funding = sponsor ? BigInt(sponsor.PAYMASTER_STAKE) + BigInt(sponsor.PAYMASTER_DEPOSIT) : 0n;
  const cost = (gasPrice * (role === 0 ? GAS.social : GAS.content) * 15n) / 10n + funding;
  const flags: string[] = [];
  if (spec.legacy) flags.push("--legacy");
  if (spec.priorityGwei) flags.push("--priority-gas-price", `${spec.priorityGwei}gwei`, "--with-gas-price", `${spec.maxFeeGwei ?? Number(spec.priorityGwei) * 2}gwei`);
  return {
    chainId: spec.chainId,
    name: spec.name,
    role,
    chain: chainOf(spec, rpc),
    rpc,
    rpcs,
    forgeFlags: flags,
    sponsor,
    balance,
    cost,
    own: own.map((url) => ({ url, ok: reachable.has(url) })),
  };
}

console.log(`\n▶ Déploiement « ${net.name} »  ·  déployeur ${account.address}\n`);
const plans = await Promise.all([plan(net.social, 0), ...net.content.map((c) => plan(c, c.role ?? 1))]);
console.log("Chain            Rôle      RPC du Registry   Solde          Requis (gas + stake + dépôt)");
for (const p of plans) {
  const role = ["social", "contenu", "ancrage"][p.role];
  console.log(`${p.name.padEnd(17)}${role.padEnd(10)}${String(p.rpcs.length).padEnd(18)}${formatEther(p.balance).slice(0, 12).padEnd(15)}${formatEther(p.cost).slice(0, 12)}`);
  for (const o of p.own) if (!o.ok) console.log(`   ⚠️  ${o.url} ne répond pas encore : il est inscrit quand même, en premier.`);
}
const short = plans.filter((p) => p.balance < p.cost && !(p.role === 0 ? state.social : state.contents[p.chainId]));
if (short.length) {
  console.log("\n⚠️  Solde probablement insuffisant sur :");
  for (const p of short) console.log(`   - ${p.name} : ~${formatEther(p.cost)} requis, ${formatEther(p.balance)} disponible`);
}
if (!args.includes("--yes")) {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const answer = await rl.question("\nContinuer et envoyer les transactions ? (oui/non) ");
  rl.close();
  if (answer.trim().toLowerCase() !== "oui") process.exit(0);
}

const env = {
  TIMELOCK_DELAY: String(net.timelock.delaySeconds),
  TIMELOCK_PROPOSER: net.timelock.proposer ?? account.address,
  MIN_STAKE: parseEther(net.stake.minStake).toString(),
  STAKE_UNIT: parseEther(net.stake.stakeUnit).toString(),
  STAKE_COOLDOWN: String(net.stake.cooldownSeconds),
  ...(net.initialAdmins.length ? { INITIAL_ADMINS: net.initialAdmins.join(",") } : {}),
};
const [social, ...contents] = plans;
for (const p of [...contents, social]) {
  const done = p.role === 0 ? state.social : state.contents[p.chainId];
  if (done) {
    console.log(`✓ ${p.name} déjà déployé`);
    state.rpcs[p.chainId] = p.rpcs;
    continue;
  }
  console.log(`\n▶ ${p.name}${p.sponsor ? " (+ paymaster)" : ""}`);
  try {
    recordDeployment(state, p, deployChain(p, pk, env));
    save();
  } catch (e) {
    if (p.role === 0) throw e;
    console.error(`✗ ${(e as Error).message} — chain ignorée, relancez pour réessayer.`);
  }
}
save();

console.log("\n▶ Registry");
await configureRegistry({ state, save, account, social, contents, params: registryParams(state, net.params, Object.fromEntries(Object.entries(net.sponsor?.chains ?? {}).map(([id, c]) => [id, c.bundlers]))) });

console.log("\n▶ Configuration du front et du relais");
publishInstance({ network: networkName, registry: state.social!.registry, chainId: net.social.chainId, rpcs: social.rpcs, devChains: false, repoUrl: net.repoUrl, frontEnvFile: ".env.production" });
console.log(`\n✓ Terminé (Registry ${state.social!.registry}). État : tooling/deployments.${networkName}.json`);
