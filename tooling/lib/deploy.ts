import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { createPublicClient, createWalletClient, fallback, http, zeroAddress, type Address, type Chain, type Hex, type LocalAccount } from "viem";
import { registryAbi } from "./abi.ts";
import { paramKey, paramValue } from "./params.ts";
import { CONTRACT_DIR, FRONT_DIR, hasFront, hasRelay, RELAY_DIR } from "./paths.ts";

export type Role = 0 | 1 | 2;

export type ChainPlan = {
  chainId: number;
  name: string;
  role: Role;
  chain: Chain;
  rpc: string;
  rpcs: string[];
  forgeFlags?: string[];
  sponsor?: Record<string, string>;
};

export type SocialDeployment = {
  chainId: number;
  deployBlock: number;
  timelock: Address;
  registry: Address;
  social: Address;
  stake: Address;
  names: Address;
  pushRelays: Address;
  media: Address;
  vault: Address;
  paymaster?: Address;
  entryPoint?: Address;
};

export type ContentDeployment = {
  chainId: number;
  deployBlock: number;
  timelock: Address;
  content: Address;
  inbox: Address;
  paymaster?: Address;
  entryPoint?: Address;
};

export type State = {
  version: 2;
  social?: SocialDeployment;
  contents: Record<string, ContentDeployment>;
  paymasters: Record<string, { chainId: number; entryPoint: Address; paymaster: Address; timelock: Address }>;
  rpcs: Record<string, string[]>;
  registry: { chains: number[]; params: Record<string, string>; ownershipTransferred: boolean };
};

export const emptyState = (): State => ({
  version: 2,
  contents: {},
  paymasters: {},
  rpcs: {},
  registry: { chains: [], params: {}, ownershipTransferred: false },
});

export function loadState(path: string): State {
  if (!existsSync(path)) return emptyState();
  const s = JSON.parse(readFileSync(path, "utf8"));
  if (s.version !== 2) throw new Error(`${path} vient de l'ancienne architecture : archivez-le avant de déployer.`);
  return s as State;
}

export const saveState = (path: string, state: State) => writeFileSync(path, JSON.stringify(state, null, 2));

export function deployChain(plan: ChainPlan, pk: Hex, env: Record<string, string>): SocialDeployment | ContentDeployment {
  mkdirSync(resolve(CONTRACT_DIR, "deployments"), { recursive: true });
  const flags = ["script", "script/Deploy.s.sol:Deploy", "--rpc-url", plan.rpc, "--broadcast", "--slow", "-q", ...(plan.forgeFlags ?? [])];
  try {
    execFileSync("forge", flags, {
      cwd: CONTRACT_DIR,
      stdio: "inherit",
      env: {
        ...process.env,
        ...env,
        ...(plan.sponsor ? { SPONSOR: "true", ...plan.sponsor } : { SPONSOR: "false" }),
        ROLE: plan.role === 0 ? "social" : "content",
        INDEXING: plan.role === 1 ? "true" : "false",
        DEPLOYER_PK: pk,
      },
    });
  } catch {
    throw new Error(`Déploiement échoué sur ${plan.name} (voir la sortie forge ci-dessus)`);
  }
  return JSON.parse(readFileSync(resolve(CONTRACT_DIR, "deployments", `${plan.chainId}.json`), "utf8"));
}

export function recordDeployment(state: State, plan: ChainPlan, d: SocialDeployment | ContentDeployment) {
  if (plan.role === 0) state.social = d as SocialDeployment;
  else state.contents[plan.chainId] = d as ContentDeployment;
  if (d.paymaster && d.entryPoint) state.paymasters[plan.chainId] = { chainId: plan.chainId, entryPoint: d.entryPoint, paymaster: d.paymaster, timelock: d.timelock };
  state.rpcs[plan.chainId] = plan.rpcs;
}

export function registryParams(state: State, base: Record<string, unknown>, bundlers: Record<string, string[]>, pushRelays?: number[]) {
  const s = state.social!;
  return {
    ...base,
    names: s.names,
    push: { chainId: s.chainId, address: s.pushRelays, deployBlock: s.deployBlock, ...(pushRelays ? { relays: pushRelays } : {}) },
    media: { [s.chainId]: s.media },
    vault: { chainId: s.chainId, address: s.vault, deployBlock: s.deployBlock },
    aa: Object.fromEntries(
      Object.values(state.paymasters).map((p) => [p.chainId, { entryPoint: p.entryPoint, paymaster: p.paymaster, bundlers: bundlers[String(p.chainId)] ?? [] }]),
    ),
    deployBlocks: Object.fromEntries([[s.chainId, s.deployBlock], ...Object.values(state.contents).map((c) => [c.chainId, c.deployBlock])]),
  };
}

export async function configureRegistry(opts: {
  state: State;
  save: () => void;
  account: LocalAccount;
  social: ChainPlan;
  contents: ChainPlan[];
  params: Record<string, unknown>;
}) {
  const { state, save, account, social } = opts;
  const s = state.social!;
  const transport = fallback(social.rpcs.length ? [http(social.rpc), ...social.rpcs.map((u) => http(u))] : [http(social.rpc)]);
  const pub = createPublicClient({ chain: social.chain, transport });
  const wallet = createWalletClient({ account, chain: social.chain, transport });
  const send = async (label: string, functionName: "addChain" | "setParams" | "transferOwnership", args: readonly unknown[]) => {
    const hash = await wallet.writeContract({ address: s.registry, abi: registryAbi, functionName, args } as never);
    const r = await pub.waitForTransactionReceipt({ hash });
    if (r.status !== "success") throw new Error(`${label} : revert (${hash})`);
    console.log(`   ✓ ${label}`);
  };
  if (state.registry.ownershipTransferred) {
    console.log("✓ Registry déjà configuré et transféré au timelock (utilisez « pnpm propose » pour le modifier).");
    return;
  }
  const chainCfg = (plan: ChainPlan, d?: ContentDeployment) => ({
    chainId: BigInt(plan.chainId),
    name: plan.name,
    content: d?.content ?? zeroAddress,
    inbox: d?.inbox ?? zeroAddress,
    role: plan.role,
    active: true,
    rpcs: plan.rpcs,
  });
  for (const plan of [social, ...opts.contents]) {
    if (state.registry.chains.includes(plan.chainId)) continue;
    const d = plan.role === 0 ? undefined : state.contents[plan.chainId];
    if (plan.role !== 0 && !d) continue;
    await send(`chain ${plan.name}`, "addChain", [chainCfg(plan, d)]);
    state.registry.chains.push(plan.chainId);
    save();
  }
  const pending = Object.entries(opts.params).filter(([k, v]) => state.registry.params[k] !== JSON.stringify(v));
  if (pending.length) {
    await send(`${pending.length} paramètre(s) : ${pending.map(([k]) => k).join(", ")}`, "setParams", [
      pending.map(([k]) => paramKey(k)),
      pending.map(([, v]) => paramValue(v)),
    ]);
    for (const [k, v] of pending) state.registry.params[k] = JSON.stringify(v);
    save();
  }
  await send("Registry transféré au timelock", "transferOwnership", [s.timelock]);
  state.registry.ownershipTransferred = true;
  save();
}

export function publishInstance(opts: { network: string; registry: Address; chainId: number; rpcs: string[]; devChains: boolean; repoUrl?: string; frontEnvFile: string }) {
  const env = [
    `VITE_REGISTRY_ADDRESS=${opts.registry}`,
    `VITE_REGISTRY_CHAIN_ID=${opts.chainId}`,
    `VITE_REGISTRY_RPCS=${opts.rpcs.join(",")}`,
    ...(opts.repoUrl ? [`VITE_REPO_URL=${opts.repoUrl}`] : []),
    `VITE_DEV_CHAINS=${opts.devChains}`,
    "",
  ].join("\n");
  if (hasFront()) {
    writeFileSync(resolve(FRONT_DIR, opts.frontEnvFile), env);
    console.log(`   ✓ ${resolve(FRONT_DIR, opts.frontEnvFile)} écrit`);
  } else console.log(`   Front absent (${FRONT_DIR}) : mettez ceci dans son ${opts.frontEnvFile} :\n${env}`);
  const relayCfg = JSON.stringify({ registry: opts.registry, chainId: opts.chainId, rpcs: opts.rpcs }, null, 2) + "\n";
  if (hasRelay()) {
    mkdirSync(resolve(RELAY_DIR, "config"), { recursive: true });
    writeFileSync(resolve(RELAY_DIR, "config", `${opts.network}.json`), relayCfg);
    console.log(`   ✓ ${resolve(RELAY_DIR, "config", `${opts.network}.json`)} écrit`);
  } else console.log(`   Relais absent (${RELAY_DIR}) : config/${opts.network}.json à créer :\n${relayCfg}`);
}
