import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  toHex,
  bytesToHex,
  parseEther,
  type Hex,
  type LocalAccount,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { contentAbi, socialAbi, inboxAbi, stakeAbi, namesAbi } from "./lib/abi.ts";
import { DEPLOYER_PK, LOCAL_CHAINS, rpcOf } from "./lib/local.ts";
import { TOOLING_DIR } from "./lib/paths.ts";
import { KIND, addressTarget, signAction, signMessage, signPrivate, type SignedMessage } from "./lib/protocol.ts";
import {
  convIdOf,
  directConvKey,
  encKeypairFromSeed,
  encryptFor,
  bucketOf,
  sealEnvelope,
  tagAt,
  tagKeyOf,
  type EnvelopeBody,
} from "./lib/crypto.ts";

const deployments = JSON.parse(readFileSync(resolve(TOOLING_DIR, "deployments.local.json"), "utf8"));
const [socialChain, freeChain, anchoredChain] = LOCAL_CHAINS;

const seedKey = (name: string) => keccak256(toHex(`arobase-dev:${name}`));
const people = ["alice", "bob", "carol", "dave"].map((name) => {
  const pk = seedKey(name);
  return { name, pk, account: privateKeyToAccount(pk), enc: encKeypairFromSeed(Uint8Array.from(Buffer.from(pk.slice(2), "hex"))) };
});
const [alice, bob, carol, dave] = people;

const clients = (c: (typeof LOCAL_CHAINS)[number], account: LocalAccount) => ({
  pub: createPublicClient({ chain: c.chain, transport: http(rpcOf(c)) }),
  wallet: createWalletClient({ account, chain: c.chain, transport: http(rpcOf(c)) }),
});

async function fund() {
  for (const c of LOCAL_CHAINS) {
    const pub = createPublicClient({ transport: http(rpcOf(c)) });
    for (const p of people) {
      await pub.request({
        method: "anvil_setBalance" as never,
        params: [p.account.address, toHex(parseEther("100"))] as never,
      });
    }
  }
}

async function publish(c: (typeof LOCAL_CHAINS)[number], who: LocalAccount, m: SignedMessage) {
  const { pub, wallet } = clients(c, who);
  const content = deployments.contents[c.chain.id].content;
  const hash = await wallet.writeContract({
    address: content,
    abi: contentAbi,
    functionName: "publish",
    args: [m.author, m.kind, m.parentId, BigInt(m.ts), m.payload, m.sig],
  });
  await pub.waitForTransactionReceipt({ hash });
  return m.id;
}

const now = () => Math.floor(Date.now() / 1000);
let clock = now() - 3600 * 6;
const tick = (s = 300) => (clock += s);

async function socialBatch(entries: { who: LocalAccount; kind: number; target: Hex; value: number }[]) {
  const { pub, wallet } = clients(socialChain, people[0].account);
  const nonces = new Map<string, bigint>();
  const actions = [];
  for (const e of entries) {
    const key = e.who.address;
    if (!nonces.has(key)) {
      nonces.set(
        key,
        await pub.readContract({ address: deployments.social.social, abi: socialAbi, functionName: "nonces", args: [key] }),
      );
    }
    const nonce = nonces.get(key)!;
    actions.push(await signAction(e.who, e.kind, e.target, e.value, nonce));
    nonces.set(key, nonce + 1n);
  }
  const hash = await wallet.writeContract({
    address: deployments.social.social,
    abi: socialAbi,
    functionName: "submitBatch",
    args: [actions],
  });
  await pub.waitForTransactionReceipt({ hash });
}

async function main() {
  await fund();

  const profiles: Record<string, { name: string; bio: string }> = {
    alice: { name: "Alice", bio: "Journaliste indépendante. Ici parce qu'on ne peut pas m'éteindre." },
    bob: { name: "Bob", bio: "Dev solidity, fan de clés privées bien rangées." },
    carol: { name: "Carol", bio: "Modératrice bénévole." },
    dave: { name: "Dave", bio: "Je poste des photos de chats." },
  };
  for (const p of people) {
    await publish(freeChain, p.account, await signMessage(p.account, KIND.PROFILE, profiles[p.name], undefined, tick(10)));
  }

  const p1 = await signMessage(alice.account, KIND.POST, { text: "Premier post sur arobase.chat. Signé, horodaté, impossible à éteindre." }, undefined, tick());
  await publish(freeChain, alice.account, p1);
  await publish(anchoredChain, alice.account, p1);

  const namesAddr = deployments.social.names;
  const { pub: sp, wallet: sw } = clients(socialChain, privateKeyToAccount(DEPLOYER_PK));
  for (const p of people) {
    const sig = await p.account.signTypedData({
      domain: { name: "arobase.chat", version: "1" },
      types: { Name: [{ name: "author", type: "address" }, { name: "name", type: "string" }, { name: "nonce", type: "uint64" }] },
      primaryType: "Name",
      message: { author: p.account.address, name: p.name, nonce: 0n },
    });
    await sp.waitForTransactionReceipt({
      hash: await sw.writeContract({ address: namesAddr, abi: namesAbi, functionName: "claim", args: [p.account.address, p.name, 0n, sig] }),
    });
  }

  const p2 = await signMessage(bob.account, KIND.POST, { text: `Les likes vivent sur une seule chain sociale, le contenu sur plusieurs. Merci @${alice.account.address} pour l'idée ! #architecture #arobase` }, undefined, tick());
  await publish(freeChain, bob.account, p2);

  const p3 = await signMessage(dave.account, KIND.POST, { text: "La Terre est plate, la preuve : mon chat tombe toujours sur ses pattes." }, undefined, tick());
  await publish(freeChain, dave.account, p3);

  const c1 = await signMessage(bob.account, KIND.COMMENT, { text: "Bienvenue ! Le post est aussi ancré sur la chain payante ?" }, p1.id, tick(60));
  await publish(freeChain, bob.account, c1);
  const c2 = await signMessage(alice.account, KIND.COMMENT, { text: "Oui, copie identique, même ID." }, c1.id, tick(60));
  await publish(freeChain, alice.account, c2);

  const note = await signMessage(carol.account, KIND.NOTE, { text: "La Terre n'est pas plate. Les chats se retournent grâce au réflexe de redressement." }, p3.id, tick(120));
  await publish(freeChain, carol.account, note);

  for (let i = 0; i < 12; i++) {
    const who = people[i % people.length];
    const tags = ["#arobase", "#web3", "#liberte", "#arobase #opensource"][i % 4];
    const m = await signMessage(who.account, KIND.POST, { text: `Post de démo n°${i + 1} par ${profiles[who.name].name}. ${tags}` }, undefined, tick(600));
    await publish(freeChain, who.account, m);
  }

  const { pub: socialPub, wallet: deployerWallet } = clients(socialChain, privateKeyToAccount(DEPLOYER_PK));
  await socialPub.waitForTransactionReceipt({
    hash: await deployerWallet.writeContract({
      address: deployments.social.stake,
      abi: stakeAbi,
      functionName: "depositFor",
      args: [carol.account.address],
      value: parseEther("1"),
    }),
  });

  const admin = privateKeyToAccount(DEPLOYER_PK);
  const adminNonce = await socialPub.readContract({
    address: deployments.social.social,
    abi: socialAbi,
    functionName: "nonces",
    args: [admin.address],
  });
  const roleAction = await signAction(admin, KIND.ROLE, addressTarget(carol.account.address), 1, adminNonce);
  await socialPub.waitForTransactionReceipt({
    hash: await deployerWallet.writeContract({
      address: deployments.social.social,
      abi: socialAbi,
      functionName: "submit",
      args: [roleAction],
    }),
  });

  await socialBatch([
    ...people.map((p) => ({ who: p.account, kind: KIND.ENC_KEY, target: bytesToHex(p.enc.publicKey), value: 0 })),
    { who: bob.account, kind: KIND.FOLLOW, target: addressTarget(alice.account.address), value: 1 },
    { who: carol.account, kind: KIND.FOLLOW, target: addressTarget(alice.account.address), value: 1 },
    { who: dave.account, kind: KIND.FOLLOW, target: addressTarget(alice.account.address), value: 1 },
    { who: alice.account, kind: KIND.FOLLOW, target: addressTarget(bob.account.address), value: 1 },
    { who: bob.account, kind: KIND.REACT, target: p1.id, value: 1 },
    { who: carol.account, kind: KIND.REACT, target: p1.id, value: 1 },
    { who: dave.account, kind: KIND.REACT, target: p2.id, value: 1 },
    { who: alice.account, kind: KIND.REACT, target: p3.id, value: -1 },
    { who: alice.account, kind: KIND.RATE_NOTE, target: note.id, value: 1 },
    { who: bob.account, kind: KIND.RATE_NOTE, target: note.id, value: 1 },
    { who: dave.account, kind: KIND.RATE_NOTE, target: note.id, value: -1 },
  ]);

  const inbox = deployments.contents[freeChain.chain.id].inbox;
  const { pub, wallet } = clients(freeChain, alice.account);
  const convKey = directConvKey(alice.enc.secretKey, bob.enc.publicKey);
  const convId = convIdOf(convKey);
  const envelopeBody: EnvelopeBody = {
    t: "dm",
    from: alice.account.address,
    fromEnc: bytesToHex(alice.enc.publicKey),
    convKey: bytesToHex(convKey),
    convId,
    epoch: 0,
    members: [alice.account.address, bob.account.address],
  };
  await pub.waitForTransactionReceipt({
    hash: await wallet.writeContract({
      address: inbox,
      abi: inboxAbi,
      functionName: "invite",
      gas: 1_000_000n,
      args: [[sealEnvelope(alice.enc.secretKey, bob.enc.publicKey, envelopeBody), sealEnvelope(alice.enc.secretKey, alice.enc.publicKey, envelopeBody)]],
    }),
  });
  const dm = await signPrivate(alice.account, convId, "Salut Bob, message chiffré de bout en bout 👋", now());
  const tag = tagAt(tagKeyOf(convKey), bucketOf(await pub.getBlockNumber()));
  await pub.waitForTransactionReceipt({
    hash: await wallet.writeContract({
      address: inbox,
      abi: inboxAbi,
      functionName: "send",
      gas: 1_000_000n,
      args: [tag, encryptFor(convKey, dm)],
    }),
  });

  console.log("\nSeed complete. Dev accounts (import them in the app via Réglages → Compte de développement):");
  for (const p of people) console.log(`  ${p.name.padEnd(6)} ${p.account.address}  ${p.pk}`);
  console.log(`  admin  ${admin.address}  ${DEPLOYER_PK}`);
}

await main();
