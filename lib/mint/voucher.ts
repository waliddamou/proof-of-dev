/**
 * Mint Voucher service — server-side EIP-712 signing for ProofOfDevV2.
 *
 * The server is the single source of truth for a wallet's score. It signs a
 * voucher binding (wallet, score, counts, hasENS, nonce, deadline) with
 * MINT_SIGNER_PRIVATE_KEY. The contract verifies that signature before minting,
 * so a user cannot fabricate their on-chain score.
 *
 * The signer key is server-side only and must match the `signer` address that
 * ProofOfDevV2 was deployed with (or was later set to via setSigner()).
 *
 * Required env (server-side only):
 *   MINT_SIGNER_PRIVATE_KEY        — private key of the trusted voucher signer
 *   NEXT_PUBLIC_ALCHEMY_API_KEY    — Sepolia RPC (used to read the on-chain nonce)
 *   NEXT_PUBLIC_CONTRACT_ADDRESS_V2 — deployed ProofOfDevV2 address
 */

import { ethers } from "ethers";
import { ReputationProfile } from "@/lib/types";
import { logger } from "@/lib/logger";
import {
  CONTRACT_V2_ABI,
  CONTRACT_V2_ADDRESS,
  POD_DOMAIN,
  VOUCHER_TYPES,
} from "@/lib/contractV2";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

/** Default voucher validity window (seconds). */
const VOUCHER_TTL_SECONDS = 60 * 60; // 1 hour

export interface SignedVoucher {
  voucher: {
    wallet: string;
    score: string;
    contractCount: string;
    verifiedContractCount: string;
    hasENS: boolean;
    nonce: string;
    deadline: string;
  };
  signature: string;
  contractAddress: string;
  chainId: number;
}

function getSigner(): ethers.Wallet {
  const pk = process.env.MINT_SIGNER_PRIVATE_KEY;
  if (!pk) {
    throw new Error(
      "MINT_SIGNER_PRIVATE_KEY is not set. Add it to .env.local to enable NFT minting (V2)."
    );
  }
  return new ethers.Wallet(pk);
}

function getProvider(): ethers.JsonRpcProvider {
  const key = process.env.NEXT_PUBLIC_ALCHEMY_API_KEY ?? "";
  return new ethers.JsonRpcProvider(`https://eth-sepolia.g.alchemy.com/v2/${key}`);
}

/**
 * Reads the wallet's current on-chain nonce from ProofOfDevV2.
 * Falls back to 0 if the contract isn't configured or the read fails — a stale
 * nonce will simply cause the on-chain mint to revert with InvalidNonce, which
 * is safe (no bad data can be minted).
 */
async function readNonce(wallet: string): Promise<bigint> {
  if (CONTRACT_V2_ADDRESS === ZERO_ADDRESS) return 0n;
  try {
    const provider = getProvider();
    const contract = new ethers.Contract(CONTRACT_V2_ADDRESS, CONTRACT_V2_ABI, provider);
    const nonce: bigint = await contract.nonces(wallet);
    return nonce;
  } catch (err) {
    logger.warn("[voucher] Failed to read on-chain nonce, defaulting to 0", (err as Error)?.message);
    return 0n;
  }
}

/**
 * Builds and signs an EIP-712 mint voucher for the given wallet + profile.
 * The score data is taken from the server-computed ReputationProfile — never
 * from client input.
 */
export async function createMintVoucher(
  wallet: string,
  profile: ReputationProfile
): Promise<SignedVoucher> {
  const signer = getSigner();
  const recipient = ethers.getAddress(wallet); // checksums + validates

  const nonce = await readNonce(recipient);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + VOUCHER_TTL_SECONDS);

  const voucher = {
    wallet: recipient,
    score: BigInt(profile.score),
    contractCount: BigInt(profile.summary.contractCount),
    verifiedContractCount: BigInt(profile.summary.verifiedContractCount),
    hasENS: profile.summary.hasENS,
    nonce,
    deadline,
  };

  const domain = { ...POD_DOMAIN, verifyingContract: CONTRACT_V2_ADDRESS };

  const signature = await signer.signTypedData(
    domain,
    VOUCHER_TYPES as unknown as Record<string, ethers.TypedDataField[]>,
    voucher
  );

  logger.info("[voucher] Signed mint voucher", {
    wallet: recipient,
    score: profile.score,
    nonce: nonce.toString(),
  });

  return {
    voucher: {
      wallet: voucher.wallet,
      score: voucher.score.toString(),
      contractCount: voucher.contractCount.toString(),
      verifiedContractCount: voucher.verifiedContractCount.toString(),
      hasENS: voucher.hasENS,
      nonce: voucher.nonce.toString(),
      deadline: voucher.deadline.toString(),
    },
    signature,
    contractAddress: CONTRACT_V2_ADDRESS,
    chainId: POD_DOMAIN.chainId,
  };
}
