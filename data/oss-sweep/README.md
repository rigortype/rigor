# OSS sweep data

Files that drive the weekly Mastodon regression sweep in
`.github/workflows/oss-sweep.yml`.

| File | Purpose |
|---|---|
| `mastodon-sha.txt` | Pinned Mastodon tag / SHA. Update when upgrading the sweep target. |
| `mastodon-rigor.yml` | Rigor config used for the sweep run (no baselines, lenient profile). |
| `mastodon-thresholds.json` | **Auto-generated** on the first passing run. Records the diagnostic counts and precision ratio that subsequent runs are gated against. Delete and re-run to recalibrate. |

## Updating the thresholds

When a Rigor improvement **reduces** the diagnostic count or **raises** the
precision ratio, the thresholds will be stale (too permissive).  Regenerate:

```sh
# 1. Delete stale thresholds.
rm data/oss-sweep/mastodon-thresholds.json

# 2. Re-run the sweep locally (requires a Mastodon checkout).
#    The first run always passes and writes new thresholds.
bash .claude/skills/rigor-regression-sweep/scripts/sweep.sh
```

Or trigger the workflow with `workflow_dispatch` — the first run without
thresholds will always pass and upload a new `mastodon-thresholds.json`
artifact that you then commit.
