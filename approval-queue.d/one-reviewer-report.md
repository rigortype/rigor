# An unattended loop may land a PR only on a review that found nothing severe, and parks everything else

- **PR:** [#3212](https://github.com/rigortype/rigor/pull/3212)
- **Issue:** none
- **Class:** open-choice
- **Precedent:** [#2138](https://github.com/rigortype/rigor/pull/2138)
- **Decided:** 2026-11-13

## Background

The maintainer asked for this rule while designing a flow that keeps running when no Claude session
is attending it. The takt lane ends at a Draft PR; waiting for CI, the adversarial review and the landing belong to a
coordinator. That makes the review the one step that needs a Claude session, and the intake gate
(`TAKT_MAX_UNLANDED`, default 5) stops new lanes once that many PRs are unlanded — so an absent
coordinator stops the implementers too, not just the reviews.

Moving the review into the unattended loop raises the question this entry answers: with the review
run by a harness and the landing run by a script, who applies § "Landing a pull request" step 3, and
how far may a loop go without a person or a Claude session reading the findings? Nothing in the
repository said. Step 3 was written for a coordinator, who may fix a severe finding conservatively
and land it.

## Options and trade-offs

- **Give the loop the coordinator's own latitude.** Simplest to write: one rule, one actor. But the
  coordinator's latitude includes fixing a severe finding and judging a fix conservative, which is
  the judgment the three-round rule exists to bound. A loop that gets it wrong lands a false
  positive, which AGENTS.md weighs above everything else.
- **Let the loop land nothing.** Safe, and it keeps the stall this change set out to remove: the
  PRs still queue behind a coordinator, and the intake gate still closes.
- **Land only where step 3 asks for no judgment, park the rest (taken).** `Severe remaining: no`,
  wording-or-spec fixes only, no advisory warning. A severe finding, a finding the loop would
  reject, an allocation hold or a serious decision leaves the PR Draft with the report posted as a
  comment. The loop keeps the cheap half of the flow moving and never decides the expensive half.
  The cost is latency on exactly the PRs that most deserve it, and a queue of parked Draft PRs that
  a returning session must drain.

## Decision

The third. It follows the precedent in substance. #2138 landed the post-hoc rule for *non-serious*
decisions by precedent, and the maintainer's merge authorisation of 2026-09-27 covers PRs that
passed the adversarial review. Both say the same thing about this case — a review that found nothing severe is the
condition, and the serious list is the boundary. What is new is only that the actor may be a script
with no model in the loop, which is why the loop is also forbidden to mark a PR ready that no review
has read: CI runners, not reviews, bound the throughput.

Deliberately out of scope: who reviews, and how many reviewers must agree. ADR-115 WD6's
co-primary pair (Grok:xhigh and `devin/swe-2`:high, both Approve) is untouched — this PR changes the
*shape* of what a reviewer returns, not the gate. A change to that gate would be a loosening, and
serious.

## To undo

Delete the "When nobody is coordinating" paragraph in
[`docs/agents/contribution-flow.md`](../docs/agents/contribution-flow.md) § "Landing a pull
request" step 3. No script reads it yet; the heartbeat that would is not written. The shared report
shape stands on its own and does not depend on this rule.
