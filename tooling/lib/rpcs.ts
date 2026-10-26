import { existsSync, readFileSync, statSync } from "node:fs";
import { resolve } from "node:path";
import { TOOLING_DIR } from "./paths.ts";

const file = resolve(TOOLING_DIR, "rpcs.local.json");
const local: Record<string, string[]> = existsSync(file) && statSync(file).isFile() ? JSON.parse(readFileSync(file, "utf8")) : {};

export function withLocalRpcs(chainId: number | string, rpcs: string[] = []) {
  const own = local[String(chainId)] ?? [];
  return [...own, ...rpcs.filter((u) => !own.includes(u))];
}
