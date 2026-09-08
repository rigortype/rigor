# frozen_string_literal: true

# ADR-107 gate G3 (issue #825) — where every declaration in `sig/` came from.
#
# `sig/` is the only place in this tree where a type may be written by hand, so ADR-107 § Decision
# gives it a provenance rule that follows ADR-5's asymmetry:
#
# - a RETURN type is generated — `rigor sig-gen` proves it from the body (ADR-5 clause 1);
# - a PARAMETER type is authored intent — inference never derives one and ADR-5 clause 2 keeps it
#   deliberately lenient, so hand-writing is legitimate there;
# - anything else hand-written is a gap `sig-gen` could not close, and by ADR-14's contradiction
#   rule the gap is the more valuable signal, so it is RECORDED rather than assumed.
#
# == The marker
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
# scanning lines. `#TBD` is accepted while a gap has no issue filed yet.
#
# == What the classifier can and cannot see
#
# `sig-gen` enumerates `def`s; `sig/` declares methods. The join is (class, method) with the
# instance / singleton kinds treated as interchangeable, because `def self?.x` in RBS and
# `module_function` in Ruby disagree about which kind a module function is. Everything else that
# separates the two — a method reached through a mixin or a superclass, a member `Data.define`
# generates, a `def` in a class `sig-gen` cannot name — lands in `:no_source`, which is residue by
# construction rather than a bug: the point of counting it is that it should shrink.
require "rbs"
require "rigor"
require "rigor/sig_gen"

class SigProvenanceAuditor
  # A declaration whose return is what `sig-gen` proves. Earned.
  GENERATED = :generated
  # Return equivalent, at least one parameter (or block) typed narrower than `untyped`. Earned —
  # ADR-5 clause 2 makes the parameter half the author's to write.
  PARAMETER_INTENT = :parameter_intent
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
  # `sig-gen` found the `def` but the RBS environment did not resolve it to this declaration.
  UNMATCHED = :unmatched_declaration
  # No `def` `sig-gen` can attribute to this declaration.
  NO_SOURCE = :no_source
  # Constants, type aliases, interfaces, `include`/`alias` members, class and module headers. No
  # return type to generate, so the provenance rule has nothing to say about them.
  NON_METHOD = :non_method

  EARNED = [GENERATED, PARAMETER_INTENT].freeze
  RESIDUE = [DECLARED_DIVERGENT, UNTRANSLATABLE, UNRENDERABLE, UNMATCHED, NO_SOURCE].freeze

  MARKER_PATTERN = /sig-gen gap:\s*#(?<issue>\d+|TBD)\b/

  Declaration = Struct.new(:path, :line, :class_name, :method_name, :kind, :typed_params, :return_rbs,
                           :marker, keyword_init: true) do
    def to_s
      "#{path}:#{line}: #{class_name}##{method_name}"
    end
  end

  Row = Struct.new(:declaration, :classification, :detail, keyword_init: true) do
    def marked? = !declaration.marker.nil?

    def residue? = RESIDUE.include?(classification) && !marked?

    def to_s
      "#{declaration}#{" — #{detail}" if detail} [#{classification}]"
    end
  end

  class << self
    # The whole audit: parse `sig/`, run `sig-gen` over `lib/`, join.
    #
    # @param root — the repository root.
    # @param candidates — pre-computed `sig-gen` output, so a caller running several assertions
    #   pays the ~14 s generator pass once.
    # @param configuration — overrides the configuration discovered under `root`; a fixture tree
    #   has no `.rigor.yml` and needs `signature_paths` pointed at its own `sig/`.
    def audit(root:, candidates: nil, configuration: nil)
      classify(declarations(root: root), candidates || generate(root: root, configuration: configuration))
    end

    # Every member of every `.rbs` under `sig/`, in file then source order.
    def declarations(root:)
      Dir.glob(File.join(root, "sig/**/*.rbs")).sort.flat_map do |file|
        read_signature(file, file.delete_prefix("#{root}/"))
      end
    end

    # `sig-gen`'s view of `lib/`. `include_private: true` because `sig/` declares private helpers
    # (`Rigor::Inference::Narrowing`'s singleton block, for one) and the default public-only pass
    # would report every one of them as `:no_source`.
    def generate(root:, paths: ["lib"], configuration: nil)
      Dir.chdir(root) do
        Rigor::SigGen::Generator.new(configuration: configuration || Rigor::Configuration.load(nil),
                                     paths: paths, observations: {}, include_private: true).run
      end
    end

    def classify(declarations, candidates)
      index = index_candidates(candidates)
      declarations.map { |decl| classify_one(decl, index) }
    end

    # `{ "sig/rigor/type.rbs" => 187 }` — unmarked residue per file, the number ADR-107 G3 keeps
    # from growing.
    def residue_counts(rows)
      rows.select(&:residue?).each_with_object(Hash.new(0)) { |row, acc| acc[row.declaration.path] += 1 }
    end

    # Prints the audit tables. The entry point `docs/notes/20260908-sig-provenance-audit.md` cites.
    def report(root: Dir.pwd, out: $stdout)
      rows = audit(root: root)
      out.puts("| classification | n |\n| --- | --- |")
      rows.group_by(&:classification).sort_by { |_, v| -v.size }
          .each { |k, v| out.puts("| `#{k}` | #{v.size} |") }
      report_per_file(rows, out)
      out.puts("\n### tighter-return (a marker is required on every one)\n")
      rows.select { |r| r.classification == TIGHTER_RETURN }.each { |r| out.puts("- #{r}") }
    end

    private

    REPORT_COLUMNS = ([TIGHTER_RETURN] + RESIDUE).freeze
    private_constant :REPORT_COLUMNS

    def report_per_file(rows, out)
      out.puts("\n| file | #{REPORT_COLUMNS.map { |r| "`#{r}`" }.join(' | ')} | earned | residue |")
      out.puts("| --- |#{' --- |' * (REPORT_COLUMNS.size + 2)}")
      rows.reject { |r| r.classification == NON_METHOD }.group_by { |r| r.declaration.path }.sort
          .each { |path, file_rows| out.puts(report_row(path, file_rows)) }
    end

    def report_row(path, rows)
      by = rows.group_by(&:classification)
      cells = REPORT_COLUMNS.map { |state| by.fetch(state, []).size }
      earned = EARNED.sum { |state| by.fetch(state, []).size }
      "| `#{path}` | #{cells.join(' | ')} | #{earned} | #{rows.count(&:residue?)} |"
    end

    def index_candidates(candidates)
      candidates.each_with_object({}) do |candidate, acc|
        next if candidate.class_name.nil?

        key = [candidate.class_name.delete_prefix("::"), candidate.method_name.to_s]
        acc[key] ||= candidate
      end
    end

    def classify_one(decl, index)
      return Row.new(declaration: decl, classification: NON_METHOD) if decl.kind.nil?

      candidate = index[[decl.class_name, decl.method_name]]
      return Row.new(declaration: decl, classification: NO_SOURCE) if candidate.nil?

      case candidate.classification
      when Rigor::SigGen::Classification::EQUIVALENT then classify_equivalent(decl, candidate)
      when Rigor::SigGen::Classification::TIGHTER_RETURN
        Row.new(declaration: decl, classification: TIGHTER_RETURN,
                detail: "declared #{candidate.declared_return_rbs}, " \
                        "sig-gen proposes #{candidate.inferred_return&.erase_to_rbs}")
      when Rigor::SigGen::Classification::SKIPPED
        Row.new(declaration: decl, classification: UNRENDERABLE,
                detail: Rigor::SigGen::Classification::SKIP_DIAGNOSTIC_IDS[candidate.skip_reason])
      else classify_new_method(decl, candidate)
      end
    end

    # `sig-gen` never compares an `initialize` against an existing declaration: it emits a
    # `(<runtime param shape>) -> void` stub unconditionally, because Ruby's constructor return
    # value is never meaningful (`Generator#initialize_stub_candidate`). So the whole of a declared
    # `-> void` constructor that `sig-gen` also emits IS the generated answer, and everything the
    # author added to it is the parameter list — ADR-5 clause 2's half, exactly.
    def classify_new_method(decl, candidate)
      if decl.method_name == "initialize" && decl.return_rbs == "void"
        return Row.new(declaration: decl, classification: decl.typed_params ? PARAMETER_INTENT : GENERATED,
                       detail: "void")
      end

      Row.new(declaration: decl, classification: UNMATCHED, detail: candidate.classification.to_s)
    end

    def classify_equivalent(decl, candidate)
      inferred = candidate.inferred_return&.erase_to_rbs
      if candidate.declared_return_rbs.nil?
        Row.new(declaration: decl, classification: UNTRANSLATABLE, detail: "sig-gen infers #{inferred}")
      elsif candidate.declared_return_rbs == inferred
        Row.new(declaration: decl, classification: decl.typed_params ? PARAMETER_INTENT : GENERATED,
                detail: inferred)
      else
        Row.new(declaration: decl, classification: DECLARED_DIVERGENT,
                detail: "declared #{candidate.declared_return_rbs}, sig-gen infers #{inferred}")
      end
    end

    def read_signature(file, relative_path)
      buffer = RBS::Buffer.new(name: Pathname(file), content: File.read(file))
      _, _, decls = RBS::Parser.parse_signature(buffer)
      collect(decls, [], relative_path)
    end

    def collect(members, namespace, path)
      members.flat_map do |member|
        case member
        when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
          nested = namespace + [member.name.to_s.delete_prefix("::")]
          [declaration(member, path, nested.join("::"), nil, nil)] + collect(member.members, nested, path)
        when RBS::AST::Members::MethodDefinition
          [declaration(member, path, namespace.join("::"), member.name.to_s, member.kind,
                       typed_params: typed_params?(member.overloads),
                       return_rbs: return_rbs(member.overloads))]
        when RBS::AST::Members::AttrReader, RBS::AST::Members::AttrWriter,
             RBS::AST::Members::AttrAccessor
          attribute_declarations(member, path, namespace.join("::"))
        else
          [declaration(member, path, namespace.join("::"), member_label(member), nil)]
        end
      end
    end

    ATTR_NAMES = {
      RBS::AST::Members::AttrReader => ->(name) { [name.to_s] },
      RBS::AST::Members::AttrWriter => ->(name) { ["#{name}="] },
      RBS::AST::Members::AttrAccessor => ->(name) { [name.to_s, "#{name}="] }
    }.freeze
    private_constant :ATTR_NAMES

    def attribute_declarations(member, path, class_name)
      ATTR_NAMES.fetch(member.class).call(member.name).map do |name|
        # A writer's parameter type is its attribute type, so a non-`untyped` attribute makes the
        # writer parameter-intent; the reader's own signature takes no parameter at all.
        typed = name.end_with?("=") && !untyped?(member.type)
        declaration(member, path, class_name, name, member.kind, typed_params: typed,
                                                                 return_rbs: member.type.to_s)
      end
    end

    def declaration(member, path, class_name, method_name, kind, typed_params: false, return_rbs: nil)
      Declaration.new(path: path, line: member.location&.start_line, class_name: class_name,
                      method_name: method_name, kind: kind, typed_params: typed_params,
                      return_rbs: return_rbs, marker: marker_for(member))
    end

    # A member with no name of its own (`include`, `alias`, an instance-variable declaration) is
    # reported by its member class so the audit's `non_method` rows stay legible.
    def member_label(member)
      return member.name.to_s if member.respond_to?(:name) && member.name

      member.class.name.split("::").last.downcase
    end

    def marker_for(member)
      text = member.respond_to?(:comment) ? member.comment&.string : nil
      match = text && MARKER_PATTERN.match(text)
      match && match[:issue]
    end

    def typed_params?(overloads)
      overloads.any? do |overload|
        function = overload.method_type.type
        next true if function.is_a?(RBS::Types::UntypedFunction)

        overload.method_type.block || function_parameters(function).any? { |p| !untyped?(p.type) }
      end
    end

    # Overloads are joined with ` | ` so a multi-overload member reads as one spelling; the only
    # comparison made against it is the exact `"void"` of a constructor, which has one overload.
    def return_rbs(overloads)
      overloads.map { |overload| overload.method_type.type.return_type.to_s }.uniq.join(" | ")
    end

    def function_parameters(function)
      function.required_positionals + function.optional_positionals +
        function.trailing_positionals + function.required_keywords.values +
        function.optional_keywords.values +
        [function.rest_positionals, function.rest_keywords].compact
    end

    def untyped?(type) = type.is_a?(RBS::Types::Bases::Any)
  end
end
