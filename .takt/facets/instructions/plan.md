Read the assigned Rigor issue and produce a short implementation plan.

Include:
- Acceptance bullets restated as checkable outcomes
- Files likely to touch
- Risks (shared clone, CI-only gates, FP surface) if relevant
- What the lane must NOT do

Whenever the plan asks for a check to be tightened — anything that turns a currently accepted call,
type or program into a diagnostic — write that step so it fails open, and say so in the plan:

- Refuse only what the engine can prove. Where the engine cannot name the runtime `self`, the receiver,
  the definition or the binding, the call stays allowed. Never phrase a fix as "require X" when
  "refuse unless X is disproved" is what keeps correct programs silent.
- List the correct programs the tightened check must leave silent, concretely enough to become specs:
  the contexts where the engine's model is coarser than Ruby (a body or block whose `self` it types as
  an instance or `main`, a name the scan does not read, an RBS-unknown class), not only the shape the
  issue reports.
- Prefer identity over surface. Where the fix hinges on "the same def" or "unchanged since", do not
  decide it by source line, by a name list of calls, or by the scanner's own entry; those miss any
  definition the scan does not read, and each miss is a report on a correct program.

A false positive outranks a missed finding (ADR-5), so an unproven refusal is a defect even when it
catches the issue's own shape.

Do not implement. Finish with "Plan ready" or "Blocked — need human".
