Create a durable git commit of the lane's changes (exclude `.takt/runs/` noise), push the branch, and open a **draft** PR with `gh pr create --draft`.

Requirements:
- Branch already exists or create `issue/<number>-...` if needed.
- PR title matches the issue intent.
- Body: what changed + Acceptance mapping; `Refs #<issue>` (not `Fixes` unless closing is intentional).
- Print the PR URL and head SHA.
- Finish with "Draft PR opened" or "Draft PR already exists" or "Ship blocked: <reason>".
