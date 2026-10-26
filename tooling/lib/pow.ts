import { randomBytes } from "node:crypto";
import { concat, encodeAbiParameters, keccak256, numberToHex, type Address, type Hex, type PublicClient, type WalletClient } from "viem";

const MAX = 2n ** 256n - 1n;

export function mineGasPrice(address: Address, nonce: number, gas: number, difficulty = 1n): bigint {
  const base = BigInt(keccak256(numberToHex(nonce, { size: 32 }))) ^ BigInt(keccak256(address));
  const div = MAX / difficulty;
  for (;;) {
    const candidate = BigInt(`0x${randomBytes(32).toString("hex")}`);
    const h = base ^ BigInt(keccak256(numberToHex(candidate, { size: 32 })));
    if (h !== 0n && div / h >= BigInt(gas)) return candidate;
  }
}

export async function claimSfuel(
  pub: PublicClient,
  wallet: WalletClient,
  faucet: { address: Address; selector: Hex },
  receiver: Address,
) {
  const account = wallet.account!;
  const nonce = await pub.getTransactionCount({ address: account.address });
  const gas = 100_000;
  const gasPrice = mineGasPrice(account.address, nonce, gas);
  const hash = await wallet.sendTransaction({
    account,
    chain: wallet.chain,
    to: faucet.address,
    data: concat([faucet.selector, encodeAbiParameters([{ type: "address" }], [receiver])]),
    gas: BigInt(gas),
    gasPrice,
    nonce,
  });
  return pub.waitForTransactionReceipt({ hash });
}
