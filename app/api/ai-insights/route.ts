/**
 * POST /api/ai-insights
 *
 * Generates a short, natural-language summary of a wallet's on-chain activity
 * using the OpenAI API. This is descriptive only — it never mints or signs
 * anything — so it accepts the already-computed analysis from the client.
 *
 * The OpenAI key stays server-side (OPENAI_API_KEY, never NEXT_PUBLIC_*).
 *
 * Body: { analysis: AnalysisResponse }
 * Response: { summary: string }
 */

import { NextRequest, NextResponse } from "next/server";
import { AnalysisResponse } from "@/lib/types";
import { logger } from "@/lib/logger";

export const runtime = "nodejs";

const OPENAI_URL = "https://api.openai.com/v1/chat/completions";
const MODEL = process.env.OPENAI_MODEL ?? "gpt-4o-mini";

/** Builds a compact, factual data digest for the model from the analysis. */
function buildFacts(analysis: AnalysisResponse) {
  const { profile, contracts, ens, includesENS, address } = analysis;

  const timestamps = contracts.map((c) => c.timestamp).filter((t) => t > 0);
  const earliest = timestamps.length ? Math.min(...timestamps) : null;
  const latest = timestamps.length ? Math.max(...timestamps) : null;
  const toDate = (t: number | null) =>
    t ? new Date(t * 1000).toISOString().slice(0, 10) : "unknown";

  return {
    address,
    score: profile.score,
    tier: profile.summary.tier,
    tierDescription: profile.summary.tierDescription,
    contractsDeployed: profile.summary.contractCount,
    verifiedContracts: profile.summary.verifiedContractCount,
    hasENS: profile.summary.hasENS,
    ensName: includesENS ? ens.name : null,
    firstDeployment: toDate(earliest),
    lastDeployment: toDate(latest),
    scoreBreakdown: profile.breakdown,
    cappedAt: profile.cappedAt,
  };
}

export async function POST(req: NextRequest) {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    return NextResponse.json(
      { error: "AI insights are not configured. Add OPENAI_API_KEY to .env.local." },
      { status: 501 }
    );
  }

  let analysis: AnalysisResponse;
  try {
    const body = await req.json();
    analysis = body.analysis as AnalysisResponse;
    if (!analysis || typeof analysis !== "object" || !analysis.profile) {
      throw new Error("missing analysis");
    }
  } catch {
    return NextResponse.json({ error: "Invalid request body" }, { status: 400 });
  }

  const facts = buildFacts(analysis);

  const systemPrompt =
    "You are a precise blockchain analyst. Given on-chain activity data for an " +
    "Ethereum wallet, write a brief, factual profile of the wallet's developer " +
    "activity. Rules: reference the actual numbers; be concise; do NOT exaggerate " +
    "or claim coding skill, code quality, or trustworthiness — this is on-chain " +
    "ACTIVITY ONLY. Write 2-3 short sentences, then up to 3 one-line observations " +
    "prefixed with '• '. Plain text only, no headings, no markdown bold.";

  try {
    const resp = await fetch(OPENAI_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: MODEL,
        temperature: 0.4,
        max_tokens: 400,
        messages: [
          { role: "system", content: systemPrompt },
          {
            role: "user",
            content:
              "Summarize this wallet's on-chain developer activity:\n\n" +
              JSON.stringify(facts, null, 2),
          },
        ],
      }),
      signal: AbortSignal.timeout(30000),
    });

    if (!resp.ok) {
      const detail = await resp.text().catch(() => "");
      logger.warn(`[ai-insights] OpenAI error ${resp.status}`, detail.slice(0, 300));
      return NextResponse.json(
        { error: `AI provider returned ${resp.status}. Check your OPENAI_API_KEY and billing.` },
        { status: 502 }
      );
    }

    const data = await resp.json();
    const summary: string = data.choices?.[0]?.message?.content?.trim() ?? "";
    if (!summary) {
      return NextResponse.json({ error: "AI returned an empty response." }, { status: 502 });
    }

    logger.info("[ai-insights] Generated summary", { address: facts.address });
    return NextResponse.json({ summary });
  } catch (err) {
    const msg = err instanceof Error ? err.message : "Unknown error";
    logger.warn("[ai-insights] Request failed", msg);
    return NextResponse.json({ error: `AI request failed: ${msg}` }, { status: 502 });
  }
}
