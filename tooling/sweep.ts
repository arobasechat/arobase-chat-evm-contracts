import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createPublicClient, createWalletClient, defineChain, formatEther, http, isAddress, parseEther, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { rankRpcs } from "./lib/chainlist.ts";
import { TOOLING_DIR } from "./lib/paths.ts";
import { withLocalRpcs } from "./lib/rpcs.ts";

const to = process.argv[2] as Address | undefined;
const networkName = process.argv[3] ?? "mainnet";
const pk = process.env.OLD_PK as Hex | undefined;
if (!to || !isAddress(to)) {
  console.log("Usage : read -rs OLD_PK && export OLD_PK && pnpm sweep <nouvelle_adresse> [network]");
  process.exit(1);
}
if (!pk || !/^0x[0-9a-fA-F]{64}$/.test(pk)) {
  console.error("OLD_PK manquant ou invalide.");
  process.exit(1);
}
const account = privateKeyToAccount(pk);
const net = JSON.parse(readFileSync(resolve(TOOLING_DIR, `networks.${networkName}.json`), "utf8"));
const chains: { chainId: number; name: string; ownRpcs?: string[]; rpcs?: string[] }[] = [net.social, ...net.content];
const L2_MARGIN = parseEther("0.00003");

console.log(`Transfert de ${account.address} → ${to}\n`);
await Promise.all(
  chains.map(async (c) => {
    try {
      const urls = [...new Set([...withLocalRpcs(c.chainId, [...(c.ownRpcs ?? []), ...(c.rpcs ?? [])]), ...(await rankRpcs(c.chainId)).slice(0, 3).map((r) => r.url)])];
      if (!urls.length) throw new Error("aucun RPC");
      const chain = defineChain({ id: c.chainId, name: c.name, nativeCurrency: { name: "Gas", symbol: "GAS", decimals: 18 }, rpcUrls: { default: { http: [urls[0]] } } });
      const readers = urls.slice(0, 3).map((u) => createPublicClient({ chain, transport: http(u, { timeout: 10_000, retryCount: 1 }) }));
      const answers = (
        await Promise.all(
          readers.map((r) =>
            Promise.all([r.getChainId(), r.getBalance({ address: account.address }), r.estimateFeesPerGas()]).catch(() => undefined),
          ),
        )
      ).filter((a): a is NonNullable<typeof a> => !!a && a[0] === c.chainId);
      if (!answers.length) throw new Error("aucun RPC fiable");
      const pub = readers[0];
      const wallet = createWalletClient({ account, chain, transport: http(urls[0]) });
      const balance = answers.reduce((m, a) => (a[1] < m ? a[1] : m), answers[0][1]);
      const fees = answers
        .map((a) => a[2])
        .reduce((m, f) => (f.maxPriorityFeePerGas < m.maxPriorityFeePerGas ? f : m));
      const floor = c.chainId === 100 ? parseEther("0.000000001") : 0n;
      const priority = fees.maxPriorityFeePerGas > floor ? fees.maxPriorityFeePerGas : floor;
      const maxFeePerGas = (fees.maxFeePerGas > priority ? fees.maxFeePerGas : priority) * 2n;
      const maxPriorityFeePerGas = priority;
      const gas = await pub.estimateGas({ account: account.address, to, value: 1n });
      const isL2 = c.chainId === 42161 || c.chainId === 8453;
      const keep = gas * maxFeePerGas + (isL2 ? L2_MARGIN : 0n);
      if (balance <= keep) return console.log(`${c.name.padEnd(14)} rien à transférer (${formatEther(balance)})`);
      const hash = await wallet.sendTransaction({ to, value: balance - keep, gas, maxFeePerGas, maxPriorityFeePerGas });
      await pub.waitForTransactionReceipt({ hash });
      console.log(`${c.name.padEnd(14)} ✓ ${formatEther(balance - keep)} transférés (${hash})`);
    } catch (e) {
      console.log(`${c.name.padEnd(14)} ✗ ${e instanceof Error ? e.message.split("\n")[0] : String(e)}`);
    }
  }),
);
