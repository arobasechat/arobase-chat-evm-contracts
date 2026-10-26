import { encodeFunctionData, keccak256, toHex, zeroHash, type Address, type Hex, type PublicClient, type WalletClient } from "viem";
import { timelockAbi } from "./abi.ts";

export async function viaTimelock(
  pub: PublicClient,
  wallet: WalletClient,
  timelock: Address,
  target: Address,
  data: Hex,
  label: string,
) {
  const delay = await pub.readContract({ address: timelock, abi: timelockAbi, functionName: "getMinDelay" });
  const salt = keccak256(toHex(`${label}:${Date.now()}`));
  const scheduleData = encodeFunctionData({
    abi: timelockAbi,
    functionName: "schedule",
    args: [target, 0n, data, zeroHash, salt, delay],
  });
  const executeData = encodeFunctionData({
    abi: timelockAbi,
    functionName: "execute",
    args: [target, 0n, data, zeroHash, salt],
  });
  const send = async (d: Hex) => {
    const hash = await wallet.sendTransaction({ account: wallet.account!, chain: wallet.chain, to: timelock, data: d });
    const r = await pub.waitForTransactionReceipt({ hash });
    if (r.status !== "success") throw new Error(`${label} : revert ${hash}`);
  };
  await send(scheduleData);
  if (delay === 0n) {
    await send(executeData);
    console.log(`   ✓ ${label} (exécuté)`);
    return { executed: true, executeData };
  }
  console.log(`   ⏳ ${label} programmé. Exécutable dans ${delay}s avec ce calldata vers ${timelock} :\n   ${executeData}`);
  return { executed: false, executeData };
}

export function timelockCalldata(target: Address, data: Hex, delay: bigint, label: string) {
  const salt = keccak256(toHex(`${label}:${Date.now()}`));
  return {
    schedule: encodeFunctionData({ abi: timelockAbi, functionName: "schedule", args: [target, 0n, data, zeroHash, salt, delay] }),
    execute: encodeFunctionData({ abi: timelockAbi, functionName: "execute", args: [target, 0n, data, zeroHash, salt] }),
  };
}
