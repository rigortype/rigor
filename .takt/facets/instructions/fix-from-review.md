Fix the adversarial review findings on the current branch.

- Work the report's findings in severity order. Fix each, or defer it with the reason. A finding
  carries a repro: make it the regression spec.
- Keep scope tight.
- Push new commits.
- Finish with "Fixes pushed" so CI can be re-watched.
