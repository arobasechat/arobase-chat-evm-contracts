const CHAINLIST = "https://chainlist.org/rpcs.json";

type Entry = { chainId: number; rpc: ({ url: string; tracking?: string } | string)[] };
export type RankedRpc = { url: string; latencyMs: number; cors: boolean };

let cache: Entry[] | undefined;

async function chainlist(): Promise<Entry[]> {
  if (!cache) {
    const res = await fetch(CHAINLIST);
    if (!res.ok) throw new Error(`Chainlist: HTTP ${res.status}`);
    cache = (await res.json()) as Entry[];
  }
  return cache;
}

async function probe(url: string, chainId: number): Promise<RankedRpc | null> {
  const start = performance.now();
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json", origin: "https://arobase.chat" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
      signal: AbortSignal.timeout(6_000),
    });
    if (!res.ok) return null;
    const json = (await res.json()) as { result?: string };
    if (!json.result || Number.parseInt(json.result, 16) !== chainId) return null;
    const acao = res.headers.get("access-control-allow-origin");
    const latencyMs = Math.round(performance.now() - start);
    let cors = acao === "*" || acao === "https://arobase.chat";
    if (cors) {
      const pre = await fetch(url, {
        method: "OPTIONS",
        headers: {
          origin: "https://arobase.chat",
          "access-control-request-method": "POST",
          "access-control-request-headers": "content-type",
        },
        signal: AbortSignal.timeout(6_000),
      }).catch(() => null);
      const preOrigin = pre?.headers.get("access-control-allow-origin");
      cors = !!pre && pre.status < 400 && (preOrigin === "*" || preOrigin === "https://arobase.chat");
    }
    return { url, latencyMs, cors };
  } catch {
    return null;
  }
}

export async function rankRpcs(chainId: number, extra: string[] = []): Promise<RankedRpc[]> {
  const entry = (await chainlist()).find((c) => c.chainId === chainId);
  const urls = [
    ...extra,
    ...(entry?.rpc ?? [])
      .map((r) => (typeof r === "string" ? { url: r } : r))
      .filter((r) => r.url.startsWith("https://") && !r.url.includes("${") && !/api[_-]?key/i.test(r.url) && r.tracking !== "yes")
      .map((r) => r.url),
  ];
  const results = await Promise.all([...new Set(urls)].map((u) => probe(u, chainId)));
  return results.filter((r): r is RankedRpc => !!r).sort((a, b) => Number(b.cors) - Number(a.cors) || a.latencyMs - b.latencyMs);
}
