"use client";

import { useState } from "react";
import { AnalysisResponse } from "@/lib/types";
import { Spinner } from "@/components/ui/Spinner";
import { NoticeBox } from "@/components/ui/NoticeBox";

interface AiInsightsProps {
  analysis: AnalysisResponse;
}

type AiState =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "done"; summary: string }
  | { status: "error"; error: string };

export function AiInsights({ analysis }: AiInsightsProps) {
  const [state, setState] = useState<AiState>({ status: "idle" });

  async function generate() {
    setState({ status: "loading" });
    try {
      const res = await fetch("/api/ai-insights", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ analysis }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "AI request failed");
      setState({ status: "done", summary: data.summary });
    } catch (err) {
      setState({
        status: "error",
        error: err instanceof Error ? err.message : "Unknown error",
      });
    }
  }

  return (
    <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6 animate-fade-in-up">
      <div className="flex items-start gap-4">
        <div className="w-12 h-12 rounded-2xl bg-gradient-to-br from-emerald-600 to-teal-700 flex items-center justify-center flex-shrink-0 shadow-lg shadow-emerald-900/30">
          <span className="text-xl">✨</span>
        </div>
        <div className="flex-1 min-w-0">
          <h3 className="text-base font-semibold text-white">AI summary</h3>
          <p className="text-sm text-slate-500 mt-0.5">
            A plain-language read of this wallet&apos;s on-chain activity, generated
            from the data above.
          </p>

          {state.status === "idle" && (
            <button
              onClick={generate}
              className="mt-4 py-2.5 px-4 bg-emerald-600 hover:bg-emerald-500 text-white font-semibold rounded-xl transition-colors text-sm flex items-center gap-2 shadow-lg shadow-emerald-900/30"
            >
              <span>✨</span>
              Analyze with AI
            </button>
          )}

          {state.status === "loading" && (
            <div className="mt-4 flex items-center gap-2 text-sm text-slate-400">
              <Spinner />
              Generating summary…
            </div>
          )}

          {state.status === "done" && (
            <div className="mt-4 space-y-3">
              <div className="bg-slate-800/50 border border-slate-800 rounded-xl p-4">
                <p className="text-sm text-slate-200 leading-relaxed whitespace-pre-line">
                  {state.summary}
                </p>
              </div>
              <div className="flex items-center justify-between">
                <p className="text-xs text-slate-600">
                  AI-generated · may contain inaccuracies · activity-based only
                </p>
                <button
                  onClick={generate}
                  className="text-xs text-emerald-400 hover:text-emerald-300 transition-colors"
                >
                  Regenerate
                </button>
              </div>
            </div>
          )}

          {state.status === "error" && (
            <div className="mt-4">
              <NoticeBox variant="error">
                <div className="space-y-2">
                  <p className="text-slate-300">{state.error}</p>
                  <button
                    onClick={generate}
                    className="px-3 py-1.5 bg-red-500/15 hover:bg-red-500/25 text-red-400 text-xs font-medium rounded-lg transition-colors border border-red-500/20"
                  >
                    Try Again
                  </button>
                </div>
              </NoticeBox>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
