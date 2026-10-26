import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createPublicClient, fallback, http, type Address } from "viem";
import { registryAbi } from "./lib/abi.ts";
import { TOOLING_DIR } from "./lib/paths.ts";
import { withLocalRpcs } from "./lib/rpcs.ts";

const networkName = process.argv[2] ?? "mainnet";
const state = JSON.parse(readFileSync(resolve(TOOLING_DIR, `deployments.${networkName}.json`), "utf8"));
const net = JSON.parse(readFileSync(resolve(TOOLING_DIR, `networks.${networkName}.json`), "utf8"));
const pub = createPublicClient({ transport: fallback(withLocalRpcs(net.social.chainId, state.rpcs[net.social.chainId]).map((u) => http(u))) });
const registry = state.social.registry as Address;

const [version, social, , chains, keys] = await pub.readContract({ address: registry, abi: registryAbi, functionName: "snapshot" });
const owner = await pub.readContract({ address: registry, abi: registryAbi, functionName: "owner" });
console.log(`Registry ${registry} v${version} · owner ${owner}${owner.toLowerCase() === state.social.timelock.toLowerCase() ? " (Timelock ✓)" : " ⚠️ pas le Timelock"}`);
console.log(`Social ${social} · ${keys.length} paramètres\n`);
for (const c of chains) {
  const results = await Promise.all(
    c.rpcs.map(async (u) => {
      try {
        const client = createPublicClient({ transport: http(u, { timeout: 6000 }) });
        const [id, code] = await Promise.all([
          client.getChainId(),
          c.role === 0 ? Promise.resolve("0x01") : client.getCode({ address: c.content }),
        ]);
        return id === Number(c.chainId) && !!code && code.length > 2;
      } catch {
        return false;
      }
    }),
  );
  const ok = results.filter(Boolean).length;
  console.log(`${c.active ? "●" : "○"} ${c.name.padEnd(16)} role ${c.role} · ${ok}/${c.rpcs.length} RPC OK${c.role ? ` · Content ${c.content}` : ""}`);
}
