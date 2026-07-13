# deep-research/ — imported external research reports

**Provenance, not findings.** Everything under this directory is **external**
material — LLM deep-research output (e.g. Gemini Deep Research, exported via
Google Docs) imported for reference. Nothing here is a Rigor first-party
claim, measurement, or evaluation, no matter how authoritative it reads.

## Register rules (how this material may be cited)

- Use it as *surveyed community / competitor landscape* only. Never cite it
  as "Rigor's docs say …" or "we measured …" — those registers require
  first-party sources (`docs/notes/`, `docs/adr/`, the CHANGELOGs).
- The bracketed citation numbers (`[5]`, …) are the generating model's own
  references: some are real, some drift from what the source says, some are
  synthetic. Verify a reference before reusing it.
- Known defect class: these reports contain **factual errors about Rigor
  itself** — the 2026-07-12 batch attributes the rigor-rs Rust port's
  internals (`ruby-prism`, `bumpalo` arena allocation) to Rigor proper and
  describes Rigor as "generating type definitions". Where a report
  contradicts the spec corpus or an ADR, the corpus binds.

## 2026-07-12 batch — Rails adoption guides (Sorbet / Steep / Rigor)

Three Gemini Deep Research runs with an identical Japanese prompt, varying
only the tool URL:

> Railsプロジェクトに <tool repo URL> の導入を検討しています。セットアップの
> 手順、導入後に必要なこと、ベストプラクティス、期待通りに型がつかないときの
> トラブルシューティングなどを、公式資料と非公式資料に分けてまとめて。

| File | Tool |
| --- | --- |
| [`20260712/rails-sorbet-adoption-guide.md`](20260712/rails-sorbet-adoption-guide.md) | Sorbet + Tapioca |
| [`20260712/rails-steep-adoption-guide.md`](20260712/rails-steep-adoption-guide.md) | Steep + rbs_rails / rbs_collection |
| [`20260712/rails-rigor-adoption-guide.md`](20260712/rails-rigor-adoption-guide.md) | Rigor |

Google-Docs Markdown exports are normalized on import — headings un-bolded,
code blocks fenced, backslash escapes removed, inline citation numbers
bracketed (see commit `0a4adf48`).

## Adding a batch

Put files under a `YYYYMMDD/` directory with unified English slugs, record
the prompt and generator in this README, and normalize the export before
committing.
