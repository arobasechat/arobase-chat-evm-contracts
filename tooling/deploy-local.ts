import { resolve } from "node:path";
import { createPublicClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { multicall3Runtime } from "./lib/abi.ts";
import { etchAccountAbstraction } from "./lib/aa.ts";
import { configureRegistry, deployChain, emptyState, publishInstance, recordDeployment, registryParams, saveState, type ChainPlan } from "./lib/deploy.ts";
import { DEPLOYER_PK, LOCAL_CHAINS, MULTICALL3, rpcOf } from "./lib/local.ts";
import { DEFAULT_PARAMS } from "./lib/params.ts";
import { TOOLING_DIR } from "./lib/paths.ts";

const SPONSOR = {
  POW_DIFFICULTY: "12",
  PAYMASTER_STAKE: "1000000000000000000",
  PAYMASTER_DEPOSIT: "10000000000000000000",
  DAILY_BUDGET: "5000000000000000000",
  PER_SENDER_DAILY: "500",
  LIMIT_PRIORITY_FEE: "100000000000",
  LIMIT_PRE_VERIFICATION_GAS: "1000000",
};

export async function deployLocal() {
  const account = privateKeyToAccount(DEPLOYER_PK);
  const statePath = resolve(TOOLING_DIR, "deployments.local.json");
  const state = emptyState();
  const save = () => saveState(statePath, state);

  for (const c of LOCAL_CHAINS) {
    const client = createPublicClient({ transport: http(rpcOf(c)) });
    await client.request({ method: "anvil_setCode" as never, params: [MULTICALL3, multicall3Runtime] as never });
    await etchAccountAbstraction(client);
  }

  const plans: ChainPlan[] = LOCAL_CHAINS.map((c) => ({
    chainId: c.chain.id,
    name: c.chain.name,
    role: c.role,
    chain: c.chain,
    rpc: rpcOf(c),
    rpcs: [rpcOf(c)],
    sponsor: SPONSOR,
  }));
  const [social, ...contents] = plans;
  for (const plan of [...contents, social]) {
    recordDeployment(state, plan, deployChain(plan, DEPLOYER_PK, { TIMELOCK_DELAY: "0", STAKE_COOLDOWN: "60" }));
    save();
  }

  const bundlers = Object.fromEntries(plans.filter((p) => p.sponsor).map((p, i) => [String(p.chainId), [`http://127.0.0.1:${4337 + i}`]]));
  await configureRegistry({ state, save, account, social, contents, params: registryParams(state, DEFAULT_PARAMS, bundlers, [0]) });

  publishInstance({ network: "local", registry: state.social!.registry, chainId: social.chainId, rpcs: [social.rpc], devChains: true, frontEnvFile: ".env.local" });
  console.log(`Déploiement local terminé (Registry ${state.social!.registry}).`);
  return state;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  await deployLocal();
}
