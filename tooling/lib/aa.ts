import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import type { Address, PublicClient } from "viem";
import { TOOLING_DIR } from "./paths.ts";

export const ENTRYPOINT_V08 = "0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108" as const;
export const SIMPLE_7702_ACCOUNT = "0xe6Cae83BdE06E4c305530e199D7217f42808555B" as const;

type Snapshot = Record<"entryPoint" | "senderCreator" | "simple7702Account", { address: Address; code: `0x${string}` }>;

export async function etchAccountAbstraction(client: PublicClient) {
  const snap = JSON.parse(readFileSync(resolve(TOOLING_DIR, "lib/aa-bytecode.json"), "utf8")) as Snapshot;
  for (const { address, code } of Object.values(snap)) {
    await client.request({ method: "anvil_setCode" as never, params: [address, code] as never });
  }
}
