import { defineChain, type Chain } from "viem";

export const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;

export const DEPLOYER_PK = (process.env.DEPLOYER_PK ??
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80") as `0x${string}`;

export type LocalChain = { chain: Chain; port: number; role: 0 | 1 | 2 };

const local = (id: number, name: string, port: number): Chain =>
  defineChain({
    id,
    name,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [`http://127.0.0.1:${port}`] } },
    contracts: { multicall3: { address: MULTICALL3 } },
  });

export const LOCAL_CHAINS: LocalChain[] = [
  { chain: local(31337, "Local Social", 8545), port: 8545, role: 0 },
  { chain: local(31338, "Local Free Content", 8546), port: 8546, role: 1 },
  { chain: local(31339, "Local Anchored", 8547), port: 8547, role: 2 },
];

export const rpcOf = (c: LocalChain) => `http://127.0.0.1:${c.port}`;
