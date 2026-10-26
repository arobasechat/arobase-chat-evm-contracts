import { stringToHex, toHex, toBytes, type Hex } from "viem";

export const paramKey = (k: string): Hex => stringToHex(k, { size: 32 });
export const paramValue = (v: unknown): Hex => toHex(toBytes(JSON.stringify(v)));

export const DEFAULT_PARAMS: Record<string, unknown> = {
  minClientVersion: 1,
  hideThreshold: 10,
  globalWindowSec: 86_400,
  globalMinWeight: 0,
  noteMinRatings: 3,
  ipfsGateways: ["https://ipfs.io/ipfs/", "https://dweb.link/ipfs/", "https://cloudflare-ipfs.com/ipfs/"],
  faucets: {},
  socialBatchMs: 1200,
};
