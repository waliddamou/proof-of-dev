/**
 * POST /api/mint-voucher
 *
 * Returns a server-signed EIP-712 voucher authorizing a ProofOfDevV2 mint.
 *
 * SECURITY: the server RE-RUNS the analysis for the address and signs the score
 * IT computes — it never trusts a score sent by the client. This is what makes
 * the on-chain badge trustworthy (closes finding F-1 in 09-SECURITY-REVIEW.md).
 *
 * Body: {
 *   address: string,
 *   network?: "mainnet" | "sepolia",
 *   includeENS?: boolean
 * }
 *
 * Response: SignedVoucher (voucher fields + signature + contractAddress + chainId)
 */

import { NextRequest, NextResponse } from "next/server";
import { enqueueAnalysis } from "@/lib/api/analyzeController";
import { createMintVoucher } from "@/lib/mint/voucher";
import { handleApiError } from "@/lib/errors/errorHandler";
import { AppError } from "@/lib/errors/AppError";

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    const { address } = body as { address?: unknown };

    if (typeof address !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(address)) {
      throw AppError.invalidAddress("address must be a valid Ethereum address");
    }

    // Re-analyze server-side — the client's score (if any) is ignored on purpose.
    const analysis = await enqueueAnalysis(body);

    const voucher = await createMintVoucher(address.toLowerCase(), analysis.profile);
    return NextResponse.json(voucher);
  } catch (err) {
    return handleApiError(err);
  }
}
