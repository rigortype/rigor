# frozen_string_literal: true

# ADR-107 gate G3 (issue #825) — where every declaration in `sig/` came from.
#
# `sig/` is the only place in this tree where a type may be written by hand, so ADR-107 § Decision
# gives it a provenance rule that follows ADR-5's asymmetry:
#
# - a RETURN type is generated — `rigor sig-gen` proves it from the body (ADR-5 clause 1);
# - a PARAMETER type is authored intent — inference never derives one and ADR-5 clause 2 keeps it
#   deliberately lenient, so hand-writing is legitimate there;
# - a `void` RETURN is authored intent for the same reason (#836): it says the return value is not
#   part of the contract, and nothing on the synthesis side produces it, since a type built from a
#   body is always the type of the body's last expression;
# - anything else hand-written is a gap `sig-gen` could not close, and by ADR-14's contradiction
#   rule the gap is the more valuable signal, so it is RECORDED rather than assumed.
#
# == The markers
#
# A recorded gap is a line in the member's own RBS comment:
#
#     # sig-gen gap: #825 — sig-gen types the body `untyped`, so the return is hand-written.
#     def resolve: (String name) -> Type::t
#
# A comment rather than a `%a{…}` annotation, on purpose. ADR-0 wants the metadata in the `.rbs`
# file and both spellings satisfy that, but the comment stays out of the `rigor:v1:` directive
# namespace `Rigor::RbsExtended` owns and ADR-20 / ADR-103 keep extending, carries no version
# token, is read by no engine path, and reads as prose. RBS binds it to the member
# (`RBS::AST::Members::MethodDefinition#comment`), so the marker is read off the AST rather than by
# scanning lines. The number must be a filed issue that tracks the ENGINE GAP: it is the pointer to
# the work that would let the generator answer, and a placeholder points at nothing, so `#TBD` is
# not a marker. Which numbers a marker may cite is the committed allow-list
# `spec/rigor/sig_gen/gap_issues.yml` (the 2026-09-19 ruling on #1011): the gate checks it offline,
# and closing a gap issue means removing it from the list, which forces the markers to move.
#
# A deliberately hand-written row — no engine work would ever let sig-gen answer it, e.g. a hook
# contract widened over code in a plugin gem sig-gen never sees — carries the other marker instead:
#
#     # authored: hook-contract widening — the element type comes from a plugin gem sig-gen never sees.
#     def template_units_for_file: (path: untyped) -> Array[untyped]
#
# Either marker marks the row: it is counted as recorded rather than residue.
#
# == What the classifier can and cannot see
#
# `sig-gen` enumerates `def`s; `sig/` declares methods. The join is (class, method, kind), except that an RBS
# `self?` declaration (`def self?.x`) joins either kind, because `def self?.x` in RBS and `module_function` in
# Ruby disagree about which kind a module function is. Everything else that
# separates the two — a method reached through a mixin or a superclass, a member `Data.define`
# generates, a `def` in a class `sig-gen` cannot name — is residue by construction rather than a bug:
# the point of counting it is that it should shrink.
#
# Issue #839 splits that population by asking a second and a third source of truth ({SigSourceIndex}):
# Rigor's own cross-file recognition, then reflection over the loaded tree. A declaration neither can
# find describes code that does not exist, and `:no_source` now means exactly that — the audit found
# nine such declarations sitting in `sig/`, which nothing in the tree checked, because `make check`
# and `make steep-check` both ask whether the implementation matches `sig/` and never the converse.
require "rbs"
require "rigor"
require "rigor/sig_gen"
require_relative "sig_declaration_reader"
require_relative "sig_parameter_shape"
require_relative "sig_provenance_report"
require_relative "sig_source_index"

class SigProvenanceAuditor
  # A declaration whose return is what `sig-gen` proves. Earned.
  GENERATED = :generated
  # Return equivalent, at least one parameter (or block) typed narrower than `untyped`. Earned —
  # ADR-5 clause 2 makes the parameter half the author's to write.
  PARAMETER_INTENT = :parameter_intent
  # The declared return is `void`. Earned, for the same reason a parameter type is: `void` says the
  # return value is not part of the contract, and no synthesis produces it — a type built from a body
  # is always the type of the body's last expression, so `void` only ever exists on the checking side
  # (`docs/type-specification/special-types.md` § `void`). `sig-gen` says so itself: it never compares
  # a `void` declaration (#836) and spells every constructor `-> void` unconditionally.
  RETURN_INTENT = :return_intent
  # `sig-gen` proposes a narrower return than the declaration. ADR-14: apply it, or record why not.
  TIGHTER_RETURN = :tighter_return
  # Declared and inferred returns differ and `sig-gen` will not propose the swap — either the
  # declaration is narrower than the body proves (which `make check` catches as
  # `def.return-type-mismatch`, ADR-107 gate G2) or one of the generator's lenience guards fired.
  DECLARED_DIVERGENT = :declared_divergent
  # `sig-gen` could not translate the declared return into a type object at all, so it compared
  # nothing. The declaration is unverified whatever it says.
  UNTRANSLATABLE = :untranslatable_declared
  # `sig-gen` declined the `def` (`sig.skipped.*` — overwhelmingly `untyped-return`).
  UNRENDERABLE = :unrenderable
  # `sig-gen` declined the `def` as `sig.skipped.untyped-return`, the declaration types at least one parameter
  # (or the block), and EVERY overload's return is the bare `untyped`. The declaration claims nothing about the
  # return, so there is nothing for the gate to doubt; it states the parameters, which are authored intent
  # (ADR-107, ADR-5 clause 2). Typing a method's parameters is what lets sig-gen render its return, and its
  # callers' returns, so the gate must not count the first step against the file's pin (#3323). Watched, not
  # waived: it is neither earned nor residue, the report prints its count per file and in total, and the row
  # leaves the class the moment sig-gen can render the return, because the declared `untyped` is then looser
  # than the generated return and reads `tighter_return` (a marker is required) or `generated`.
  PARAMETER_ONLY = :parameter_only
  # `sig-gen` found the `def` but the RBS environment did not resolve it to this declaration.
  UNMATCHED = :unmatched_declaration
  # No `def`, but Rigor's own recognition finds the method on the declaring class: an `attr_*`, a
  # `define_method`, an `alias`, a `Data` / `Struct` member, or a `def` `sig-gen` declines to emit.
  SYNTHETIC = :synthetic_source
  # No `def` on the class, but the project declares the method on an ancestor it also declares.
  INHERITED = :inherited_source
  # Nothing static explains it and reflection over the loaded tree does: a method a class macro or a
  # generated ancestor defines at load.
  RUNTIME_DEFINED = :runtime_defined
  # Nothing finds the method — not `sig-gen`, not the project index, not the runtime. The declaration
  # describes code that does not exist (#839); ADR-107 G3 fails on one.
  NO_SOURCE = :no_source
  # Constants, type aliases, interfaces, `include`/`alias` members, class and module headers. No
  # return type to generate, so the provenance rule has nothing to say about them.
  NON_METHOD = :non_method

  # Neither earned nor residue; counted on its own so the number can be watched fall.
  WATCHED = [PARAMETER_ONLY].freeze
  EARNED = [GENERATED, PARAMETER_INTENT, RETURN_INTENT].freeze
  # The three #839 states are residue, not earned: knowing that a declared method EXISTS says nothing
  # about where its type came from, and the type is what ADR-107 § Decision asks about. Splitting them
  # out of `:no_source` therefore leaves every per-file residue pin exactly where it was.
  RESIDUE = [DECLARED_DIVERGENT, UNTRANSLATABLE, UNRENDERABLE, UNMATCHED, SYNTHETIC, INHERITED,
             RUNTIME_DEFINED, NO_SOURCE].freeze

  Declaration = SigDeclarationReader::Declaration

  # `paired` — sig-gen produced a candidate for the declaration; `source_defs` — every `Prism::DefNode` sig-gen's walk
  # recorded for the declaration's `[class, method, kind]`, in any file, candidate or not. Both feed only the
  # parameter-shape check ({SigParameterShape}, #3335); the classification never reads them.
  Row = Struct.new(:declaration, :classification, :detail, :paired, :source_defs, keyword_init: true) do
    def marked? = !declaration.marker.nil? || !declaration.authored_reason.nil?

    # A marker records a row without changing that it is watched: `marked?` rows still count here.
    def watched? = WATCHED.include?(classification)

    def residue? = RESIDUE.include?(classification) && !marked?

    def to_s
      "#{declaration} — #{classification}#{" (#{detail})" if detail}"
    end
  end

  # One `sig-gen` run's candidates, the project environment that run built (the elaborator reads
  # generic arity from it), and every `def` node its walk collected, by `[class, method, kind]`.
  Generated = Struct.new(:candidates, :environment, :def_nodes, keyword_init: true)

  # `Generator#run` keeps the environment it built in `@environment`; this subclass only exposes it, and records
  # every `def` the walk collects by `[class, method, kind]` across files (#3335). The walk runs before sig-gen drops
  # a def it makes no candidate of (a parameterless `initialize`, a slot an `if` / `else` pair contests), so those
  # defs are recorded too, and a class reopened in two files keeps both.
  class EnvironmentKeepingGenerator < Rigor::SigGen::Generator
    def elaboration_environment = @environment

    def def_nodes = @def_nodes || {}

    private

    def collect_method_definitions(root, scope_index)
      super.tap do |defs|
        defs.each do |def_node, class_name, kind|
          ((@def_nodes ||= {})[[class_name, def_node.name.to_s, kind]] ||= []) << def_node if class_name
        end
      end
    end
  end
  private_constant :Generated, :EnvironmentKeepingGenerator

  class << self
    # The whole audit: parse `sig/`, run `sig-gen` over `lib/`, join.
    #
    # @param root — the repository root.
    # @param candidates — pre-computed `sig-gen` output, so a caller running several assertions
    #   pays the ~14 s generator pass once.
    # @param configuration — overrides the configuration discovered under `root`; a fixture tree
    #   has no `.rigor.yml` and needs `signature_paths` pointed at its own `sig/`.
    # @param runtime — let the #839 tiers require `root`'s own `lib/` and reflect over it. Off by
    #   default: requiring a tree runs its code, and a fixture tree's `lib/` is written by the
    #   example auditing it.
    # @param environment — required with `candidates:`: sig-gen's project environment for that run.
    # @param def_nodes — with `candidates:`, the walk's defs by `[class, method, kind]` (see {Generated}); omitted, no
    #   row is compared by {SigParameterShape}.
    def audit(root:, candidates: nil, environment: nil, def_nodes: {}, configuration: nil, runtime: false)
      if candidates && environment.nil?
        raise ArgumentError, "audit: candidates need environment: (sig-gen's project environment)"
      end

      generated = candidates ? nil : generate(root: root, configuration: configuration)
      classify(declarations(root: root), candidates || generated.candidates,
               sources: SigSourceIndex.build(root: root, runtime: runtime),
               environment: candidates ? environment : generated.environment,
               def_nodes: candidates ? def_nodes : generated.def_nodes)
    end

    # Every member of every `.rbs` under `sig/`, in file then source order.
    def declarations(root:)
      SigDeclarationReader.declarations(root: root)
    end

    # `sig-gen`'s view of `lib/`. `include_private: true` because `sig/` declares private helpers
    # (`Rigor::Inference::Narrowing`'s singleton block, for one) and the default public-only pass
    # would report every one of them as `:no_source`.
    def generate(root:, paths: ["lib"], configuration: nil)
      Dir.chdir(root) do
        generator = EnvironmentKeepingGenerator.new(configuration: configuration || Rigor::Configuration.load(nil),
                                                    paths: paths, observations: {}, include_private: true)
        candidates = generator.run
        Generated.new(candidates: candidates, environment: generator.elaboration_environment,
                      def_nodes: generator.def_nodes)
      end
    end

    # `environment:` is the project environment sig-gen built for the run. An inferred return is elaborated
    # through {Rigor::SigGen::TypeElaborator} with it before comparison, so the classifier compares the
    # spelling `rigor sig-gen` writes, not the raw carrier (a bare generic carries no `untyped` parameter
    # until the elaborator fills it in). `environment: nil` compares the raw spelling, spelled out so no caller
    # reaches it by omission; only the unit examples with no sig-gen run pass it.
    def classify(declarations, candidates, environment:, sources: SigSourceIndex::NONE, def_nodes: {})
      index = index_candidates(candidates)
      declarations.map do |decl|
        row = classify_one(decl, index, sources, environment)
        if decl.kind
          row.paired = !candidate_for(decl, index).nil?
          row.source_defs = recorded_defs(decl, def_nodes)
        end
        row
      end
    end

    # `{ "sig/rigor/type.rbs" => 187 }` — unmarked residue per file, the number ADR-107 G3 keeps
    # from growing.
    def residue_counts(rows)
      rows.select(&:residue?).each_with_object(Hash.new(0)) { |row, acc| acc[row.declaration.path] += 1 }
    end

    # Prints the audit tables. The entry point `docs/notes/20260908-sig-provenance-audit.md` and
    # `docs/notes/20260909-sig-no-source-audit.md` cite. `runtime: true` — a report of the repository's
    # own `sig/` wants the #839 tiers, and the audit is what the two notes are made of.
    def report(root: Dir.pwd, out: $stdout, runtime: true)
      rows = audit(root: root, runtime: runtime)
      SigProvenanceReport.render(rows, out: out, shapes: SigParameterShape.check(rows))
    end

    private

    # Keyed on the candidate's kind as well as its name, so a declaration joins the candidate for its own kind:
    # an instance `def` no longer shadows a singleton candidate of the same name (or the reverse).
    def index_candidates(candidates)
      candidates.each_with_object({}) do |candidate, acc|
        next if candidate.class_name.nil?

        key = [candidate.class_name.delete_prefix("::"), candidate.method_name.to_s, candidate.kind]
        acc[key] ||= candidate
      end
    end

    # The candidate a declaration joins. The RBS kind `self?` (`def self?.x`, `:singleton_instance`) names both
    # kinds at once, so only it falls back to the other kind's candidate; every other declaration joins its own.
    def candidate_for(decl, index)
      exact = index[[decl.class_name, decl.method_name, decl.kind == :singleton ? :singleton : :instance]]
      return exact if exact || decl.kind != :singleton_instance

      index[[decl.class_name, decl.method_name, :singleton]] || index[[decl.class_name, decl.method_name, :instance]]
    end

    # The walk's defs for a declaration's slot. `self?` names both kinds, as in {#candidate_for}.
    def recorded_defs(decl, def_nodes)
      kinds = { singleton: [:singleton], singleton_instance: %i[singleton instance] }.fetch(decl.kind, [:instance])
      kinds.flat_map { |kind| def_nodes.fetch([decl.class_name, decl.method_name, kind], []) }
    end

    # `SigSourceIndex`'s vocabulary, mapped onto the audit's. Kept as a table so a new tier there is
    # one row here rather than a branch.
    MISSING_SOURCE = { SigSourceIndex::SYNTHETIC => SYNTHETIC, SigSourceIndex::INHERITED => INHERITED,
                       SigSourceIndex::RUNTIME => RUNTIME_DEFINED }.freeze
    private_constant :MISSING_SOURCE

    def classify_one(decl, index, sources, environment)
      return Row.new(declaration: decl, classification: NON_METHOD) if decl.kind.nil?

      candidate = candidate_for(decl, index)
      return classify_unattributed(decl, sources) if candidate.nil?

      case candidate.classification
      when Rigor::SigGen::Classification::EQUIVALENT then classify_equivalent(decl, candidate, environment)
      when Rigor::SigGen::Classification::TIGHTER_RETURN
        Row.new(declaration: decl, classification: TIGHTER_RETURN,
                detail: "declared #{candidate.declared_return_rbs}, " \
                        "sig-gen proposes #{candidate.inferred_return&.erase_to_rbs}")
      when Rigor::SigGen::Classification::SKIPPED then classify_skipped(decl, candidate)
      else classify_new_method(decl, candidate)
      end
    end

    # `parameter_only` needs all three: sig-gen skipped the def for `untyped-return` specifically (any other skip
    # reason says nothing about the return), a typed parameter or block, and a declared return that is the bare
    # `untyped` in every overload. A block's own return type is not the method's return and is not read.
    def classify_skipped(decl, candidate)
      detail = Rigor::SigGen::Classification::SKIP_DIAGNOSTIC_IDS[candidate.skip_reason]
      if candidate.skip_reason == :untyped_return && decl.types_something && decl.untyped_return
        return Row.new(declaration: decl, classification: PARAMETER_ONLY, detail: detail)
      end

      Row.new(declaration: decl, classification: UNRENDERABLE, detail: detail)
    end

    # Issue #839 — `sig-gen` attributed no `def` to this declaration. Ask the project index, then the
    # runtime; only a declaration none of the three can find is stale.
    def classify_unattributed(decl, sources)
      found, detail = sources.explain(decl.class_name, decl.method_name)
      return Row.new(declaration: decl, classification: NO_SOURCE) if found.nil?

      Row.new(declaration: decl, classification: MISSING_SOURCE.fetch(found), detail: detail)
    end

    # `sig-gen` never compares an `initialize`'s return against an existing declaration: it writes a
    # `(<runtime param shape>) -> void` stub, because Ruby's constructor return value is never
    # meaningful (`Generator#initialize_stub_candidate`). Since #1436 a constructor the class declares
    # is `equivalent` carrying `void`, which {#classify_equivalent} reads; the stub still reaches this
    # arm when observations would tighten the declaration, and the declared `-> void` is
    # {RETURN_INTENT} here too — everything the author added to it is the parameter list.
    def classify_new_method(decl, candidate)
      return Row.new(declaration: decl, classification: RETURN_INTENT, detail: "void") if decl.return_rbs == "void"

      Row.new(declaration: decl, classification: UNMATCHED, detail: candidate.classification.to_s)
    end

    def classify_equivalent(decl, candidate, environment)
      inferred = elaborated_return(candidate.inferred_return, environment)
      if candidate.declared_return_rbs == "void"
        # `sig-gen` compared nothing: the declaration is `void`, so there is no value contract to
        # prove (`Generator#declares_void?`). The `void` is read off the candidate rather than the
        # declaration so the gate and the generator cannot disagree about which spelling counts.
        Row.new(declaration: decl, classification: RETURN_INTENT, detail: "void")
      elsif candidate.declared_return_rbs.nil?
        Row.new(declaration: decl, classification: UNTRANSLATABLE, detail: "sig-gen infers #{inferred}")
      elsif candidate.declared_return_rbs == inferred
        Row.new(declaration: decl, classification: decl.typed_params ? PARAMETER_INTENT : GENERATED,
                detail: inferred)
      else
        Row.new(declaration: decl, classification: DECLARED_DIVERGENT,
                detail: "declared #{candidate.declared_return_rbs}, sig-gen infers #{inferred}")
      end
    end

    # The spelling `sig-gen` writes for an inferred return: bare generics filled in by
    # {Rigor::SigGen::TypeElaborator}, then erased. A written `Set` keeps `untyped` for its element (#2177).
    def elaborated_return(type, environment)
      return nil if type.nil?
      return type.erase_to_rbs if environment.nil?

      Rigor::SigGen::TypeElaborator.elaborate(type, environment: environment).erase_to_rbs
    end
  end
end
