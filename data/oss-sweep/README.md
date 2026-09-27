# OSS sweep data

Files that drive the weekly Mastodon regression sweep in
`.github/workflows/oss-sweep.yml`.

| File | Purpose |
|---|---|
| `mastodon-sha.txt` | Pinned Mastodon tag / SHA. Update when upgrading the sweep target. |
| `mastodon-rigor.yml` | Rigor config used for the sweep run (no baselines, lenient profile). |
| `mastodon-thresholds.json` | The diagnostic count and precision ratio that runs are gated against. Set by hand from a recorded CI run; its `note` says which run and why. |

## Updating the thresholds

When a Rigor change **reduces** the diagnostic count or **raises** the
precision ratio, tighten the thresholds so the gate keeps its teeth. When it
**raises** the count, diff the new rows against the previous run for false
positives first, and fix a false positive at its root rather than blessing it.

Take the numbers from a CI run, not a local one: the release-gate and weekly
runs print `Total:` and the coverage ratio in the Mastodon sweep job, and upload
the diagnostics JSON as an artifact. Edit `max_diagnostics` and
`min_precision_ratio` by hand, and update `calibrated_at` and `note` to name
that run.

The `workflow_dispatch` input `recalibrate: true` writes fresh values from one
run to an uploaded `mastodon-thresholds-updated.json` artifact. It does not
commit anything, and the file it writes has no `note`, so add one before you
commit it.
