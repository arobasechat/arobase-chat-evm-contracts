import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createPublicClient, createWalletClient, encodeFunctionData, fallback, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { registryAbi, timelockAbi } from "./lib/abi.ts";
import { rankRpcs } from "./lib/chainlist.ts";
import { paramKey, paramValue } from "./lib/params.ts";
import { TOOLING_DIR } from "./lib/paths.ts";
import { withLocalRpcs } from "./lib/rpcs.ts";
import { timelockCalldata, viaTimelock } from "./lib/timelock.ts";

const [, , command, ...rest] = process.argv;
const option = (name: string) => {
  const i = rest.indexOf(`--${name}`);
  return i >= 0 ? rest[i + 1] : undefined;
};
const positional = rest.filter((a, i) => !a.startsWith("--") && !rest[i - 1]?.startsWith("--"));
const networkName = option("network") ?? "mainnet";
const calldataOnly = rest.includes("--calldata");
const state = JSON.parse(readFileSync(resolve(TOOLING_DIR, `deployments.${networkName}.json`), "utf8"));
const net =
  networkName === "local"
    ? { social: { chainId: 31337, name: "Local Social" }, rpcsPerChain: 5 }
    : JSON.parse(readFileSync(resolve(TOOLING_DIR, `networks.${networkName}.json`), "utf8"));
const socialRpcs = networkName === "local" ? ["http://127.0.0.1:8545"] : withLocalRpcs(net.social.chainId, state.rpcs?.[net.social.chainId] ?? []);
const registry = state.social.registry as Address;
const timelock = state.social.timelock as Address;

async function readParam(key: string) {
  const answers = await Promise.all(
    socialRpcs.map((url) =>
      createPublicClient({ transport: http(url, { timeout: 10_000, retryCount: 1 }) })
        .readContract({ address: registry, abi: registryAbi, functionName: "params", args: [paramKey(key)] })
        .catch(() => undefined),
    ),
  );
  const seen = [...new Set(answers.filter((a): a is Hex => a !== undefined))];
  if (!seen.length) throw new Error(`Paramètre ${key} illisible : aucun RPC n'a répondu`);
  if (seen.length > 1) throw new Error(`Les RPC renvoient des valeurs différentes pour ${key} : refus de réécrire le paramètre`);
  const responded = answers.filter(Boolean).length;
  if (responded < Math.min(2, socialRpcs.length)) throw new Error(`Un seul RPC a répondu pour ${key} : impossible de recouper la valeur`);
  const before = JSON.parse(Buffer.from(seen[0].slice(2), "hex").toString("utf8"));
  return { before, snapshot: JSON.stringify(before) };
}

function showChange(key: string, before: string, after: unknown) {
  console.log(`\n${key} actuel (recoupé sur ${socialRpcs.length} RPC) :\n  ${before}\n${key} proposé :\n  ${JSON.stringify(after)}\n`);
}

async function chainIndex(pub: ReturnType<typeof createPublicClient>, chainId: number) {
  const chains = await pub.readContract({ address: registry, abi: registryAbi, functionName: "getChains" });
  const i = chains.findIndex((c) => Number(c.chainId) === chainId);
  if (i < 0) throw new Error(`Chain ${chainId} absente du Registry`);
  return { index: BigInt(i), cfg: chains[i] };
}

async function main() {
  const pub = createPublicClient({ transport: fallback(socialRpcs.map((u) => http(u))) });
  let data: Hex;
  switch (command) {
    case "set-param":
      data = encodeFunctionData({ abi: registryAbi, functionName: "setParam", args: [paramKey(positional[0]), paramValue(JSON.parse(positional[1]))] });
      break;
    case "set-active": {
      const { index } = await chainIndex(pub, Number(positional[0]));
      data = encodeFunctionData({ abi: registryAbi, functionName: "setChainActive", args: [index, positional[1] === "true"] });
      break;
    }
    case "refresh-rpcs": {
      const chainId = Number(positional[0]);
      const { index } = await chainIndex(pub, chainId);
      const avoid: string[] = net.avoidRpcs ?? [];
      const ranked = (await rankRpcs(chainId)).filter((r) => !avoid.some((a) => r.url.includes(a)));
      const rpcs = ranked.filter((r) => r.cors).slice(0, net.rpcsPerChain).map((r) => r.url);
      console.log(`RPC retenus pour ${chainId} :\n  ${rpcs.join("\n  ")}`);
      data = encodeFunctionData({ abi: registryAbi, functionName: "setRpcs", args: [index, rpcs] });
      break;
    }
    case "set-bundlers": {
      const chainId = positional[0];
      const urls = positional.slice(1);
      const { before: aa, snapshot } = await readParam("aa");
      if (!aa[chainId]) throw new Error(`Pas de config ERC-4337 pour la chain ${chainId}`);
      aa[chainId].bundlers = urls;
      showChange("aa", snapshot, aa);
      data = encodeFunctionData({ abi: registryAbi, functionName: "setParam", args: [paramKey("aa"), paramValue(aa)] });
      break;
    }
    case "set-push-relays": {
      const ids = positional.map(Number);
      if (ids.some((n) => !Number.isInteger(n) || n < 0)) throw new Error("Identifiants de relais invalides");
      const { before: push, snapshot } = await readParam("push");
      push.relays = ids;
      showChange("push", snapshot, push);
      console.log(`Relais vérifiés : ${ids.length ? ids.join(", ") : "aucun (liste vide : tous les relais deviennent non vérifiés)"}`);
      data = encodeFunctionData({ abi: registryAbi, functionName: "setParam", args: [paramKey("push"), paramValue(push)] });
      break;
    }
    case "update-delay":
      data = encodeFunctionData({ abi: timelockAbi, functionName: "updateDelay", args: [BigInt(positional[0])] });
      break;
    default:
      console.log(`Usage : pnpm propose <commande> [--network mainnet] [--calldata]
  set-param <clé> <json>          ex. set-param hideThreshold 15
  set-active <chainId> true|false
  refresh-rpcs <chainId>          (re-sélectionne les RPC depuis Chainlist)
  set-bundlers <chainId> <url…>   (liste publique des bundlers ERC-4337)
  set-push-relays <id…>           (relais push vérifiés, proposés par défaut dans l'app)
  update-delay <secondes>         (délai du Timelock, ex. 86400)
  --calldata                      affiche le calldata pour un Safe au lieu d'envoyer`);
      return;
  }
  const target = command === "update-delay" ? timelock : registry;
  if (calldataOnly) {
    const delay = await pub.readContract({ address: timelock, abi: timelockAbi, functionName: "getMinDelay" });
    const c = timelockCalldata(target, data, delay, command);
    console.log(`Safe → to: ${timelock}\n1) schedule: ${c.schedule}\n2) après ${delay}s, execute: ${c.execute}`);
    return;
  }
  const pk = (process.env.DEPLOYER_PK ?? (networkName === "local" ? "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" : undefined)) as Hex | undefined;
  if (!pk) throw new Error("DEPLOYER_PK requis (proposer du Timelock).");
  const account = privateKeyToAccount(pk);
  const chainId = await pub.getChainId();
  const wallet = createWalletClient({
    account,
    chain: { id: chainId, name: net.social.name, nativeCurrency: { name: "Gas", symbol: "GAS", decimals: 18 }, rpcUrls: { default: { http: socialRpcs } } },
    transport: fallback(socialRpcs.map((u) => http(u))),
  });
  await viaTimelock(pub as never, wallet, timelock, target, data, command);
}

await main();
