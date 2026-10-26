import { spawn, type ChildProcess } from "node:child_process";
import { resolve } from "node:path";
import { CONTRACT_DIR } from "./paths.ts";
import { ENTRYPOINT_V08 } from "./aa.ts";

const EXECUTORS = [
  "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
  "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e",
  "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6",
];
const UTILITY = [
  "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356",
  "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97",
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
];

export function startBundler(rpc: string, port: number, index: number): ChildProcess {
  const proc = spawn(
    resolve(CONTRACT_DIR, "node_modules/.bin/alto"),
    [
      "--entrypoints", ENTRYPOINT_V08,
      "--executor-private-keys", EXECUTORS[index],
      "--utility-private-key", UTILITY[index],
      "--rpc-url", rpc,
      "--port", String(port),
      "--safe-mode", "false",
      "--min-entity-stake", "1",
      "--min-entity-unstake-delay", "1",
      "--log-level", "warn",
      "--enable-cors", "true",
      "--fixed-gas-limit-for-estimation", "8000000",
      "--supports-eip7623", "true",
    ],
    { stdio: ["ignore", "inherit", "inherit"] },
  );
  process.on("exit", () => proc.kill("SIGINT"));
  return proc;
}
