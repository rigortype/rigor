# frozen_string_literal: true

require_relative "classification"

module Rigor
  module SigGen
    # Answers for the `sig.skipped.*` identifiers `rigor sig-gen` prints when it declines to emit a
    # signature for a method.
    #
    # ADR-108 WD4 — a skip id is an ANSWER ("Rigor cannot prove a type here"), and the command that exists
    # to answer identifiers must be able to answer it. `rigor explain` resolves against
    # {Analysis::RuleCatalog}, which carries diagnostic rules only, so `rigor explain
    # sig.skipped.untyped-return` used to reply `Unknown rule` for an id Rigor had just printed. This is the
    # second catalogue `explain` consults; it is deliberately separate from the rule catalog because a skip
    # reason has no severity, no profile mapping and no suppression, and forcing it into {RuleCatalog::Entry}
    # would mean inventing four fields that do not apply.
    #
    # Every id in {Classification::SKIP_DIAGNOSTIC_IDS} MUST have an entry here; the gate is
    # `spec/rigor/sig_gen/skip_reason_catalog_spec.rb`.
    module SkipReasonCatalog
      class Entry < Data.define(:id, :summary, :explanation, :next_step)
        # Hash-shaped form for `rigor explain --format=json`. String keys, and `kind` distinguishes a skip
        # reason from a rule entry in a stream a consumer may receive either from.
        def to_h
          {
            "id" => id,
            "kind" => "sig_skip_reason",
            "summary" => summary,
            "explanation" => explanation,
            "next_step" => next_step
          }
        end
      end

      ENTRIES = {
        "sig.skipped.untyped-return" => Entry.new(
          id: "sig.skipped.untyped-return",
          summary: "The method's return types as Dynamic[top], so no signature was written.",
          explanation: "Rigor inferred the body but the value it returns has no proven type — the last " \
                       "expression widened to Dynamic[top] somewhere up its chain. Emitting `untyped` here " \
                       "would record noise as a contract: the file would gain a signature that says nothing " \
                       "and stops a later, better inference from being noticed. This is the commonest skip " \
                       "reason on a project whose dependencies have no RBS.",
          next_step: "Do not write the return type by hand — the skip is the finding. Trace the returned " \
                     "expression back to where it became dynamic (`rigor annotate PATH` reads the `#=>` " \
                     "column, `rigor trace --format=json --line=N` for one line) and close THAT: install or " \
                     "write RBS for the dependency, enable the plugin for the framework, or report an " \
                     "engine gap."
        ),
        "sig.skipped.user-authored" => Entry.new(
          id: "sig.skipped.user-authored",
          summary: "An RBS declaration for this method already exists and was left alone.",
          explanation: "Not a gap. The project already states a type for this member, and sig-gen does not " \
                       "overwrite a hand-authored contract without being told to. Where `sig/` and an inline " \
                       "annotation both declare the member, `sig/` wins.",
          next_step: "Read the existing declaration. If it disagrees with what Rigor infers, raise the " \
                     "disagreement rather than silently retyping it; pass `--overwrite` only once you have " \
                     "decided the generated type is the better contract."
        ),
        "sig.skipped.unrenderable-rbs" => Entry.new(
          id: "sig.skipped.unrenderable-rbs",
          summary: "Rigor rendered a line that `rbs` itself rejects, so the method was dropped.",
          explanation: "A defect in Rigor's renderer, not in your code. The method is skipped rather than " \
                       "written so one pathological signature cannot make the whole generated file " \
                       "unparseable, and the count is reported so the defect is not silent.",
          next_step: "Report it, with the method and the file. `rigor sig-gen --print PATH` shows what was " \
                     "generated for the rest of the file and is the useful attachment."
        ),
        "sig.skipped.complex-shape" => Entry.new(
          id: "sig.skipped.complex-shape",
          summary: "Reserved for a shape too complex to render; no code path produces it today.",
          explanation: "The identifier is part of the reserved `sig.skipped.*` family and is carried so the " \
                       "family stays stable, but no generator path emits it.",
          next_step: "If you have actually seen this id in output, that is itself worth reporting — it means " \
                     "a path exists that this catalogue does not describe."
        ),
        "sig.skipped.unresolvable-superclass" => Entry.new(
          id: "sig.skipped.unresolvable-superclass",
          summary: "The class's superclass chain does not end in a class the RBS environment knows.",
          explanation: "Writing the declaration would make things worse rather than better: RBS would read " \
                       "the class as rooted at an unknown parent and collapse it on the next run, losing the " \
                       "members it can resolve today.",
          next_step: "Give the environment the missing ancestor — install or write RBS for the gem that " \
                     "defines it, or add the project file that declares it to the analysed paths — then " \
                     "re-run `rigor sig-gen`."
        ),
        "sig.skipped.overridden-by-unsigned-subclass" => Entry.new(
          id: "sig.skipped.overridden-by-unsigned-subclass",
          summary: "A subclass overrides this method and its override was not itself emitted.",
          explanation: "A declaration on the parent is inherited by every subclass that does not redeclare " \
                       "the member. Emitting it here would hand the subclass a type describing the parent's " \
                       "body, not the override the subclass actually runs.",
          next_step: "Generate signatures for the overriding subclass too — widen the `sig-gen` path set to " \
                     "cover it — and the parent's declaration becomes safe to emit."
        )
      }.freeze

      module_function

      # @param token — a `sig.skipped.*` identifier.
      # @return the matching entry, or nil when the token is not a known skip reason.
      def resolve(token)
        ENTRIES[token.to_s]
      end

      def all
        ENTRIES.values
      end
    end
  end
end
