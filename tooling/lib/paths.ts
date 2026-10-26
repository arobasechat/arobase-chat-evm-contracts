import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const TOOLING_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const CONTRACT_DIR = resolve(TOOLING_DIR, "..");
export const FRONT_DIR = resolve(process.env.FRONT_DIR ?? resolve(CONTRACT_DIR, "../arobase-chat-front"));
export const RELAY_DIR = resolve(process.env.RELAY_DIR ?? resolve(CONTRACT_DIR, "../arobase-chat-push-relay"));

export const hasFront = () => existsSync(resolve(FRONT_DIR, "package.json"));
export const hasRelay = () => existsSync(resolve(RELAY_DIR, "package.json"));
