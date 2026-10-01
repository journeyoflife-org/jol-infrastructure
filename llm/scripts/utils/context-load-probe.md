# Context-load verification (Phase 4) — runbook

Answers the one question the config change alone cannot: **does `qwen3-32b-q8_0`
served at the native 32,768 window actually fit inside the `llm-prod-lt01` RAM
budget, and at what prefill/decode cost?** Phase 1 raised the context from the
deliberate 8,192 to 32,768; that is *intended*, not *measured*. Ollama sizes the
KV cache from `num_ctx` at model load, so the extra memory only appears when the
model is loaded at the wider window.

## Why this script and not the existing ones
- `benchmark-model.sh` measures throughput at a fixed `num_ctx=2048` — it never
  exercises the 32k KV footprint.
- `memory-profile.sh` samples RSS *passively*; nothing drives a large-context load
  while it samples.
- `context-load-probe.sh` loads the model at the target context and samples peak
  resident memory *during* that load, then asserts the documented admission ceiling.

## Prerequisites (must be true first)
1. The 32,768 serving config is **deployed** on lt01 — i.e. `jol-infrastructure`
   PR raising `OLLAMA_CONTEXT_LENGTH` + the `qwen3-32b-q8.Modelfile` `num_ctx` is
   merged and applied (`systemctl restart ollama` or the install/verify scripts).
   Against an 8,192 deployment this honestly reports the 8k footprint, not 32k.
2. Run **on the box** (`llm-prod-lt01`). The probe reads `/proc/<ollama>/status`
   and the loopback engine API `http://127.0.0.1:11434`; the external endpoint is
   air-gapped and unreachable from a workstation.

## Run
```bash
# on llm-prod-lt01, with a jol-llm checkout available for the results log:
JOL_LLM_REPO=/path/to/jol-llm ./llm/scripts/utils/context-load-probe.sh qwen3-32b-q8_0 32768
# overrides: RSS_CEILING_GIB (default 80), RUNS (default 3)
```
Exit 0 = PASS (peak RSS ≤ ceiling), exit 1 = FAIL (over the admission ceiling).

## What it prints / records
Median prefill tok/s, generation tok/s, prefill wall-seconds, and **peak ollama
RSS (GiB)** during load, appended as a row to
`jol-llm/models/benchmarks/lt01-context-load-results.csv`
(`date,host,model,quant,threads,num_ctx,prefill_tok_s,gen_tok_s,prefill_s,peak_rss_gib,ceiling_gib,verdict`).
These are observed numbers only — the tool never invents a figure.

## Acceptance ceilings (with source, not invented)
| Check | Ceiling | Source |
|---|---|---|
| Peak RSS at 32k context | ≤ 80 GiB | `jol-llm docs/04-operations/capacity-planning.md` — "Model RAM need > 80 GiB → reject on lt01" (96 GiB host) |
| TTFT, ≤512-token prompt | < 5 s (median) | `jol-llm docs/01-architecture/service-dependencies.md` — downstream latency contract; enforced by `jol-llm tests/integration/test_model_inference.sh` |
| Generation drift | re-run if p95 > 2× baseline | `capacity-planning.md` scaling signals |

Phase 1 estimate for a PASS: KV ≈ 16 GiB at 32k (linear from the documented ~4 GiB
at 8k) + ~34 GiB weights + ~4 GiB base ≈ **~54 GiB resident**, comfortably under 80.
**This is an estimate — the probe exists to replace it with a measurement.**

## Related verifications (do not duplicate here)
- SLA over the full mTLS path (Caddy → bridge → Ollama): `jol-llm tests/integration/test_model_inference.sh`.
- Concurrency / queue behaviour: `jol-llm tests/load/locustfile.py` (single slot ⇒ keep users low).
- The fleet-facing claim (which provider, region, connectivity status) lives in
  `jol-hermes-agents docs/audit/LLM_CONNECTIVITY_MATRIX.md` — update it off
  "UNVERIFIED" only once this probe + the SLA test have produced real numbers.
