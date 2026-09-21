Watch CI on the draft PR for this task.

- Poll with `gh pr view <n> --json statusCheckRollup,status,commits` at most once per minute.
- Do not use `gh pr checks` in a tight loop.
- When all required checks are success: "CI green".
- When any required check failed: "CI red" and summarize failing jobs.
- If still pending after a long stall: "CI stalled".
