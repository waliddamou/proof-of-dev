/**
 * ProofOfDevV2 contract config — address, ABI, and EIP-712 domain.
 *
 * V2 replaces the self-attested mint of V1 with a server-signed voucher. The
 * frontend fetches a voucher from POST /api/mint-voucher, then calls mint(voucher,
 * signature) so the on-chain score is provably the one the server computed.
 *
 * Set NEXT_PUBLIC_CONTRACT_ADDRESS_V2 in .env.local after deploying ProofOfDevV2.
 */

import { sepolia } from "wagmi/chains";

export const CONTRACT_V2_ADDRESS =
  process.env.NEXT_PUBLIC_CONTRACT_ADDRESS_V2 ||
  "0x0000000000000000000000000000000000000000";

/** EIP-712 domain — MUST match the contract's _buildDomainSeparator() exactly. */
export const POD_DOMAIN = {
  name: "Proof of Dev",
  version: "2",
  chainId: sepolia.id, // 11155111
} as const;

/** EIP-712 typed-data fields — MUST match the Voucher struct field order. */
export const VOUCHER_TYPES = {
  Voucher: [
    { name: "wallet", type: "address" },
    { name: "score", type: "uint256" },
    { name: "contractCount", type: "uint256" },
    { name: "verifiedContractCount", type: "uint256" },
    { name: "hasENS", type: "bool" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export interface Voucher {
  wallet: `0x${string}`;
  score: bigint;
  contractCount: bigint;
  verifiedContractCount: bigint;
  hasENS: boolean;
  nonce: bigint;
  deadline: bigint;
}

export const CONTRACT_V2_ABI = [
  // ── Reads ──
  {
    inputs: [{ internalType: "address", name: "account", type: "address" }],
    name: "balanceOf",
    outputs: [{ internalType: "uint256", name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [{ internalType: "address", name: "", type: "address" }],
    name: "nonces",
    outputs: [{ internalType: "uint256", name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [{ internalType: "address", name: "account", type: "address" }],
    name: "getTokenByAddress",
    outputs: [{ internalType: "uint256", name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [{ internalType: "uint256", name: "tokenId", type: "uint256" }],
    name: "getMetadata",
    outputs: [
      {
        components: [
          { internalType: "uint256", name: "score", type: "uint256" },
          { internalType: "uint256", name: "contractCount", type: "uint256" },
          { internalType: "uint256", name: "verifiedContractCount", type: "uint256" },
          { internalType: "bool", name: "hasENS", type: "bool" },
          { internalType: "uint256", name: "mintedAt", type: "uint256" },
          { internalType: "uint256", name: "updatedAt", type: "uint256" },
        ],
        internalType: "struct ProofOfDevV2.DevMetadata",
        name: "",
        type: "tuple",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "signer",
    outputs: [{ internalType: "address", name: "", type: "address" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "paused",
    outputs: [{ internalType: "bool", name: "", type: "bool" }],
    stateMutability: "view",
    type: "function",
  },
  // ── Writes ──
  {
    inputs: [
      {
        components: [
          { internalType: "address", name: "wallet", type: "address" },
          { internalType: "uint256", name: "score", type: "uint256" },
          { internalType: "uint256", name: "contractCount", type: "uint256" },
          { internalType: "uint256", name: "verifiedContractCount", type: "uint256" },
          { internalType: "bool", name: "hasENS", type: "bool" },
          { internalType: "uint256", name: "nonce", type: "uint256" },
          { internalType: "uint256", name: "deadline", type: "uint256" },
        ],
        internalType: "struct ProofOfDevV2.Voucher",
        name: "voucher",
        type: "tuple",
      },
      { internalType: "bytes", name: "signature", type: "bytes" },
    ],
    name: "mint",
    outputs: [{ internalType: "uint256", name: "tokenId", type: "uint256" }],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      {
        components: [
          { internalType: "address", name: "wallet", type: "address" },
          { internalType: "uint256", name: "score", type: "uint256" },
          { internalType: "uint256", name: "contractCount", type: "uint256" },
          { internalType: "uint256", name: "verifiedContractCount", type: "uint256" },
          { internalType: "bool", name: "hasENS", type: "bool" },
          { internalType: "uint256", name: "nonce", type: "uint256" },
          { internalType: "uint256", name: "deadline", type: "uint256" },
        ],
        internalType: "struct ProofOfDevV2.Voucher",
        name: "voucher",
        type: "tuple",
      },
      { internalType: "bytes", name: "signature", type: "bytes" },
    ],
    name: "updateScore",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [{ internalType: "uint256", name: "tokenId", type: "uint256" }],
    name: "burn",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  // ── Events ──
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: "address", name: "to", type: "address" },
      { indexed: true, internalType: "uint256", name: "tokenId", type: "uint256" },
      { indexed: false, internalType: "uint256", name: "score", type: "uint256" },
    ],
    name: "Minted",
    type: "event",
  },
] as const;
