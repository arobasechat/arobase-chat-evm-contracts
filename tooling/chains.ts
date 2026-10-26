import { spawn, type ChildProcess } from "node:child_process";
import { createPublicClient, http } from "viem";
import { LOCAL_CHAINS, rpcOf } from "./lib/local.ts";

export async function waitForRpc(url: string, timeoutMs = 15_000) {
  const client = createPublicClient({ transport: http(url) });
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      await client.getChainId();
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 200));
    }
  }
  throw new Error(`RPC ${url} did not start`);
}

export async function startChains(): Promise<ChildProcess[]> {
  const procs = LOCAL_CHAINS.map(({ chain, port }) =>
    spawn(
      "anvil",
      ["--port", String(port), "--chain-id", String(chain.id), "--silent", "--code-size-limit", "50000", "--hardfork", "prague"],
      { stdio: "inherit" },
    ),
  );
  const stop = () => procs.forEach((p) => p.kill("SIGINT"));
  process.on("SIGINT", () => {
    stop();
    process.exit(0);
  });
  process.on("exit", stop);
  await Promise.all(LOCAL_CHAINS.map((c) => waitForRpc(rpcOf(c))));
  for (const c of LOCAL_CHAINS) console.log(`anvil ${c.chain.name} (${c.chain.id}) → ${rpcOf(c)}`);
  return procs;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  await startChains();
  console.log("Chains running. Ctrl+C to stop.");
}
