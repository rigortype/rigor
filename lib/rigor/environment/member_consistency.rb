# frozen_string_literal: true

require "rbs"

require_relative "../type"
require_relative "../inference/rbs_type_translator"

module Rigor
  class Environment
    # ADR-112 WD5 / issue #1075 — the consistency rule for one member declared by two sources. It replaces
    # ADR-32 WD13's "`sig/` wins per member": a `sig/` declaration and an inline (`@rbs` / `#:`) one of the
    # same member are compared instead of ranked.
    #
    # - **Consistent** — each type position of one side is a subtype of the same position on the other.
    #   `untyped` (and `void` / `top`, which RBS defines as the same top type) is consistent with everything
    #   and is the least precise answer, so a migrating project's `sig/ -> untyped` beside an inline `-> void`
    #   stays quiet (ADR-93's herb case). The two merge to the more precise side: when every position of the
    #   inline member is at least as precise as `sig/`'s and one is strictly more, the inline member binds and
    #   the `sig/` one stands down; otherwise `sig/` binds. Nothing is reported either way.
    # - **Contradiction** — some position where each side is provably outside the other (both `accepts`
    #   answers are `no`), a positional arity range disjoint from the other's, or a keyword one side requires
    #   and the other cannot accept. `sig/` still binds, so the class builds, and the run reports
    #   `rbs.contradicting-signature` as an error.
    # - **Undecided** — anything Rigor cannot rank: a position whose type it cannot read faithfully (an
    #   alias, an interface, `self`, a type variable, a proc), a `maybe` either way, shapes that differ
    #   without contradicting (a different overload count, an optional parameter on one side), or each side
    #   more precise in a different position. `sig/` binds and the dropped inline member is reported at
    #   `:info` under ADR-32 WD12, as every inline member was before.
    #
    # The false-positive discipline holds the DEFINITION of a contradiction (ADR-112 WD5), which is why every
    # doubt lands in "undecided" rather than in the error. Disjointness is only ever proven by
    # `Inference::Acceptance`, whose class-hierarchy answer comes from classes loaded in the analyzer process:
    # two project classes never contradict each other here, however unrelated.
    #
    # The same comparison answers `rbs-extended.md`'s "an annotation whose refinement exceeds the ordinary
    # RBS contract is a conflict": a `rigor:v1:return:` / `rigor:v1:param:` payload that the member's own
    # declared type provably does not accept is a contradiction between two statements of one member's
    # contract, reported under the same identifier.
    #
    # The comparison works on one member PAIR and knows nothing about where either side came from, so a
    # third source (ADR-112's `@extrbs`, #1073) plugs in as another caller of {.compare} without changing it.
    #
    # Pure over RBS AST members: no environment is consulted, so {RbsLoader} derives the same answer from its
    # inputs at build time and on an environment-cache HIT.
    module MemberConsistency # rubocop:disable Metrics/ModuleLength
      # One outcome per `(class, method, kind)` key two sources declare, or per member whose refinement
      # exceeds its own declared type (`outcome: :refinement`). `signature_path` / `signature_line` locate
      # the `.rbs` member (nil for a refinement record read off an inline member); `virtual_name` is the
      # synthesized buffer name of the inline source (nil for a refinement record read off a `.rbs` member).
      Record = Data.define(:class_name, :method_name, :kind, :outcome, :detail, :signature_path,
                           :signature_line, :virtual_name)

      # What the environment build needs from the rule: which inline keys stand down, and which `.rbs`
      # members stand down per file (because the inline side was the more precise one).
      Resolution = Data.define(:records, :inline_standdowns, :signature_standdowns)

      EMPTY = Ractor.make_shareable(
        Resolution.new(records: [], inline_standdowns: Set.new, signature_standdowns: {})
      )

      # Outcomes that report, and how loud.
      ERROR_OUTCOMES = %i[contradiction refinement].freeze
      INFO_OUTCOMES = %i[undecided].freeze

      # A type position: the declared RBS type, and the `rigor:v1:` refinement that overrides it (or nil).
      Slot = Data.define(:rbs_type, :override)
      private_constant :Slot

      # The RBS leaf types whose Rigor translation loses nothing a precision comparison could depend on.
      FAITHFUL_LEAVES = [
        ::RBS::Types::Bases::Any, ::RBS::Types::Bases::Bool, ::RBS::Types::Bases::Nil,
        ::RBS::Types::Bases::Top, ::RBS::Types::Bases::Bottom, ::RBS::Types::Bases::Void,
        ::RBS::Types::Literal, ::RBS::Types::ClassSingleton
      ].freeze
      private_constant :FAITHFUL_LEAVES

      # RBS's three spellings of the top type ("they are all equivalent for the type system" — rbs
      # `docs/syntax.md`). None says anything about the value, so each is the least precise answer a position
      # can give, and two of them are equal.
      TOP_SPELLINGS = [::RBS::Types::Bases::Any, ::RBS::Types::Bases::Top, ::RBS::Types::Bases::Void].freeze
      private_constant :TOP_SPELLINGS

      # The two silent verdicts {.compare} answers most often, shared rather than rebuilt per member.
      EQUAL = [:equal, nil].freeze
      SIGNATURE_MORE_PRECISE = [:signature, nil].freeze
      NO_STRINGS = [].freeze
      private_constant :EQUAL, :SIGNATURE_MORE_PRECISE, :NO_STRINGS

      RETURN_DIRECTIVE_PREFIX = "rigor:v1:return:"
      PARAM_DIRECTIVE_PREFIX = "rigor:v1:param:"
      # `RbsExtended::INFERRED_SIGNATURE_DIRECTIVE`, spelled here so reading it does not load `RbsExtended`.
      INFERRED_SIGNATURE_DIRECTIVE = "rigor:v1:inferred-signature"
      private_constant :RETURN_DIRECTIVE_PREFIX, :PARAM_DIRECTIVE_PREFIX, :INFERRED_SIGNATURE_DIRECTIVE

      class << self
        # @param signature_members — `{[class, method, kind] => [signature_path, member]}`, the first project
        #   `.rbs` member declaring each key.
        # @param inline_members — `[[virtual_name, class_name, member], ...]`, every member the inline sources
        #   declare.
        # @return a {Resolution}. Records are sorted and deduplicated; silent outcomes are recorded too, so a
        #   caller can see what merged where.
        def resolve(signature_members, inline_members)
          return EMPTY if inline_members.empty?

          # Loaded here rather than with the file: {RbsLoader} requires this module on every run, and only a
          # project with inline RBS ever compares anything.
          require_relative "../inference/acceptance"
          require_relative "../rbs_extended"

          state = { records: [], inline: Set.new, signature: Hash.new { |hash, file| hash[file] = Set.new },
                    checked: {}.compare_by_identity }
          inline_members.each do |virtual_name, class_name, member|
            state[:records].concat(refinement_records(class_name, member, nil, virtual_name))
            resolve_member(state, signature_members, virtual_name, class_name, member)
          end
          Resolution.new(
            records: state[:records].uniq.sort_by { |r| record_sort_key(r) }.freeze,
            inline_standdowns: state[:inline].freeze,
            signature_standdowns: state[:signature].transform_values(&:freeze).freeze
          )
        end

        # The `[method_name, kind]` pairs one RBS member contributes to a definition build, mirroring
        # `RBS::DefinitionBuilder::MethodBuilder#build_instance` / `#build_singleton` — which is what decides
        # whether two members collide. An attribute contributes its reader and / or writer name (`foo`,
        # `foo=`), an alias its new name, and `def self?.x` both sides. An `overloading?` member (`def x: ...
        # | ...`) contributes NOTHING: rbs files those under `overloads` rather than `originals`, so they are
        # designed to compose with an existing declaration and are never compared against it.
        def member_method_keys(member)
          case member
          when ::RBS::AST::Members::MethodDefinition then method_definition_keys(member)
          when ::RBS::AST::Members::AttrReader then [[member.name, member.kind]]
          when ::RBS::AST::Members::AttrWriter then [[:"#{member.name}=", member.kind]]
          when ::RBS::AST::Members::AttrAccessor then [[member.name, member.kind], [:"#{member.name}=", member.kind]]
          when ::RBS::AST::Members::Alias then [[member.new_name, member.kind]]
          else []
          end
        end

        private

        # Compares the two members' declarations of one method name.
        #
        # @return `[outcome, detail]` — `outcome` is `:equal`, `:signature` (`sig/` is more precise),
        #   `:inline` (the inline side is more precise), `:contradiction` or `:undecided`; `detail` names the
        #   deciding position for the two reported outcomes and is nil otherwise.
        def compare(signature_member, inline_member, method_name)
          return EQUAL if same_declaration?(signature_member, inline_member)
          return SIGNATURE_MORE_PRECISE if inferred_signature?(inline_member)

          if signature_member.is_a?(::RBS::AST::Members::Alias) || inline_member.is_a?(::RBS::AST::Members::Alias)
            return compare_aliases(signature_member, inline_member)
          end

          sig_overloads = overloads_for(signature_member, method_name)
          inline_overloads = overloads_for(inline_member, method_name)
          if sig_overloads.size != inline_overloads.size
            return [:undecided, "the two declare a different number of overloads"]
          end

          sig_refinements = refinements_of(signature_member)
          inline_refinements = refinements_of(inline_member)
          results = sig_overloads.each_with_index.flat_map do |sig_type, index|
            prefix = sig_overloads.size > 1 ? "overload #{index + 1}, " : ""
            compare_method_types(sig_type, inline_overloads[index], sig_refinements, inline_refinements, prefix)
          end
          combine(results)
        end

        # The details of every `rigor:v1:return:` / `rigor:v1:param:` refinement on `member` that its own
        # declared type provably does not accept, in declaration order. Empty for a member carrying no such
        # annotation, which is the cheap common case.
        def refinement_conflicts(member)
          return [] unless member_annotation_strings(member).any? { |string| refinement_directive?(string) }

          return_override, param_overrides = refinements_of(member)
          member_method_types(member).flat_map do |method_type|
            refinement_conflicts_in(method_type, return_override, param_overrides)
          end.uniq
        end

        def resolve_member(state, signature_members, virtual_name, class_name, member)
          overlapping = member_method_keys(member).filter_map do |method_name, kind|
            key = [class_name, method_name, kind]
            owner = signature_members[key]
            owner && [key, *owner]
          end
          return if overlapping.empty?

          verdicts = overlapping.map do |key, path, sig_member|
            record_signature_refinements(state, class_name, sig_member, path)
            [key, path, sig_member, compare(sig_member, member, key[1])]
          end
          apply_verdicts(state, verdicts, inline_binds?(verdicts, overlapping.map(&:first), class_name), virtual_name)
        end

        # Records each key's outcome and files the losing side: every `.rbs` member the inline one displaces
        # when it binds, or every shared inline key when `sig/` does.
        def apply_verdicts(state, verdicts, inline_binds, virtual_name)
          verdicts.each do |key, path, sig_member, verdict|
            if inline_binds
              state[:signature][path].merge(full_keys(key[0], sig_member))
              verdict = [:inline, nil]
            else
              state[:inline] << key
              verdict = reported_verdict(verdict)
            end
            state[:records] << record(key, verdict, path, sig_member, virtual_name)
          end
        end

        # The inline member binds only when every key it shares is at least as precise inline, one is
        # strictly more, and swapping loses nothing: each `.rbs` member it displaces declares no key the
        # inline member does not also declare (an `attr_accessor` in `sig/` against an inline `def foo`
        # would otherwise take `foo=` down with it).
        def inline_binds?(verdicts, shared_keys, class_name)
          outcomes = verdicts.map { |_, _, _, verdict| verdict.first }
          return false unless outcomes.all? { |outcome| %i[equal inline].include?(outcome) }
          return false unless outcomes.include?(:inline)

          shared = shared_keys.to_set
          verdicts.all? { |_, _, sig_member, _| full_keys(class_name, sig_member).all? { |key| shared.include?(key) } }
        end

        # A key where the inline side was more precise, but the member as a whole could not bind, lost
        # something the author wrote: that is WD12's "parsed and not honoured", so it reports as undecided.
        def reported_verdict(verdict)
          if verdict.first == :inline
            return [:undecided,
                    "the inline declaration is more precise here but could not replace the `.rbs` member"]
          end

          verdict
        end

        def full_keys(class_name, member)
          member_method_keys(member).map { |method_name, kind| [class_name, method_name, kind] }
        end

        # The `.rbs` line is read only for an outcome that reports it: asking an `RBS::Buffer` for a line
        # builds that buffer's whole line table, a cost a silent merge has no use for.
        def record(key, verdict, path, sig_member, virtual_name)
          line = ERROR_OUTCOMES.include?(verdict[0]) ? member_line(sig_member) : nil
          Record.new(
            class_name: key[0], method_name: key[1], kind: key[2], outcome: verdict[0], detail: verdict[1],
            signature_path: path, signature_line: line, virtual_name: virtual_name
          )
        end

        # The common case after `rigor sig-gen` has written an annotated member into `sig/`: the two
        # declarations are the same text, annotations included, and nothing needs translating.
        def same_declaration?(signature_member, inline_member)
          return false unless signature_member.instance_of?(inline_member.class)
          return false unless signature_member.annotations == inline_member.annotations

          case signature_member
          when ::RBS::AST::Members::MethodDefinition then signature_member.overloads == inline_member.overloads
          when ::RBS::AST::Members::AttrReader, ::RBS::AST::Members::AttrWriter, ::RBS::AST::Members::AttrAccessor
            signature_member.type == inline_member.type
          else false
          end
        end

        def record_signature_refinements(state, class_name, sig_member, path)
          return if state[:checked].key?(sig_member)

          state[:checked][sig_member] = true
          state[:records].concat(refinement_records(class_name, sig_member, path, nil))
        end

        # `path` is the `.rbs` file for a `sig/` member (whose line is then read) and nil for an inline one.
        def refinement_records(class_name, member, path, virtual_name)
          conflicts = refinement_conflicts(member)
          return NO_STRINGS if conflicts.empty?

          method_name, kind = member_method_keys(member).first || [member_name(member), :instance]
          line = path && member_line(member)
          conflicts.map do |detail|
            Record.new(class_name: class_name, method_name: method_name, kind: kind, outcome: :refinement,
                       detail: detail, signature_path: path, signature_line: line, virtual_name: virtual_name)
          end
        end

        def member_name(member)
          member.respond_to?(:name) ? member.name : member.new_name
        end

        def member_line(member)
          location = member.respond_to?(:location) ? member.location : nil
          location.respond_to?(:start_line) ? location.start_line : nil
        end

        # `Symbol#name` and `nil.to_s` are frozen, so the key allocates nothing but itself.
        def record_sort_key(record)
          [record.class_name, record.method_name.name, record.kind.name, record.outcome.name,
           record.virtual_name.to_s, record.signature_path.to_s, record.detail.to_s]
        end

        def method_definition_keys(member)
          return [] if member.respond_to?(:overloading?) && member.overloading?

          case member.kind
          when :instance then [[member.name, :instance]]
          when :singleton then [[member.name, :singleton]]
          else [[member.name, :instance], [member.name, :singleton]] # `def self?.x` defines both sides
          end
        end

        # rbs-inline's skeleton for a `def` whose annotations asserted nothing about it (ADR-93 WD6,
        # `%a{rigor:v1:inferred-signature}`): no author wrote this inline side, so it has nothing to be
        # consistent or inconsistent with, and `sig/` binds without a word.
        def inferred_signature?(member)
          member_annotation_strings(member).include?(INFERRED_SIGNATURE_DIRECTIVE)
        end

        def compare_aliases(signature_member, inline_member)
          both = signature_member.is_a?(::RBS::AST::Members::Alias) && inline_member.is_a?(::RBS::AST::Members::Alias)
          return [:equal, nil] if both && signature_member.old_name == inline_member.old_name

          [:undecided, "an alias cannot be compared with another declaration"]
        end

        # The method types one member declares for `method_name`: an attribute reads as `() -> T` (reader)
        # or `(T) -> T` (writer), which is the method RBS builds from it.
        def overloads_for(member, method_name)
          case member
          when ::RBS::AST::Members::MethodDefinition then member.overloads.map(&:method_type)
          when ::RBS::AST::Members::AttrReader, ::RBS::AST::Members::AttrWriter, ::RBS::AST::Members::AttrAccessor
            [attribute_method_type(member.type, writer: method_name.to_s.end_with?("="))]
          else []
          end
        end

        def member_method_types(member)
          case member
          when ::RBS::AST::Members::MethodDefinition then member.overloads.map(&:method_type)
          when ::RBS::AST::Members::AttrReader, ::RBS::AST::Members::AttrAccessor
            [attribute_method_type(member.type, writer: false)]
          when ::RBS::AST::Members::AttrWriter then [attribute_method_type(member.type, writer: true)]
          else []
          end
        end

        def attribute_method_type(type, writer:)
          positionals = writer ? [::RBS::Types::Function::Param.new(type: type, name: nil)] : []
          function = ::RBS::Types::Function.new(
            required_positionals: positionals, optional_positionals: [], rest_positionals: nil,
            trailing_positionals: [], required_keywords: {}, optional_keywords: {}, rest_keywords: nil,
            return_type: type
          )
          ::RBS::MethodType.new(type_params: [], type: function, block: nil, location: nil)
        end

        def compare_method_types(sig_type, inline_type, sig_refinements, inline_refinements, prefix)
          return [[:equal, nil]] if sig_refinements == inline_refinements && sig_type == inline_type
          unless sig_type.type_params.empty? && inline_type.type_params.empty?
            return [[:undecided,
                     "#{prefix}a generic method type"]]
          end

          compare_functions(sig_type.type, inline_type.type, sig_refinements, inline_refinements, prefix) +
            compare_blocks(sig_type.block, inline_type.block, prefix)
        end

        def compare_blocks(sig_block, inline_block, prefix)
          return [] if sig_block.nil? && inline_block.nil?
          return [[:undecided, "#{prefix}only one side declares a block"]] if sig_block.nil? || inline_block.nil?
          if sig_block.required != inline_block.required
            return [[:undecided,
                     "#{prefix}the block is required on one side only"]]
          end

          compare_functions(sig_block.type, inline_block.type, [nil, {}], [nil, {}], "#{prefix}block ")
        end

        def compare_functions(sig_fn, inline_fn, sig_refinements, inline_refinements, prefix)
          results = compare_parameters(sig_fn, inline_fn, sig_refinements[1], inline_refinements[1], prefix)
          results << compare_slot(
            "#{prefix}return type",
            Slot.new(rbs_type: sig_fn.return_type, override: sig_refinements[0]),
            Slot.new(rbs_type: inline_fn.return_type, override: inline_refinements[0])
          )
          results
        end

        # `(?) -> T` declares nothing about its parameters, so the other side's parameter list is the more
        # precise one — or they are equal when both are untyped.
        def compare_parameters(sig_fn, inline_fn, sig_params, inline_params, prefix)
          sig_untyped = sig_fn.is_a?(::RBS::Types::UntypedFunction)
          inline_untyped = inline_fn.is_a?(::RBS::Types::UntypedFunction)
          return [] if sig_untyped && inline_untyped
          return [[:inline, nil]] if sig_untyped
          return [[:signature, nil]] if inline_untyped

          unless function_shape(sig_fn) == function_shape(inline_fn)
            return [shape_contradiction(sig_fn, inline_fn, prefix) ||
                    [:undecided, "#{prefix}the parameter lists have different shapes"]]
          end

          parameter_pairs(sig_fn, inline_fn).map do |label, sig_param, inline_param|
            compare_slot(
              "#{prefix}#{label}",
              Slot.new(rbs_type: sig_param.type, override: sig_param.name && sig_params[sig_param.name]),
              Slot.new(rbs_type: inline_param.type, override: inline_param.name && inline_params[inline_param.name])
            )
          end
        end

        def function_shape(function)
          [function.required_positionals.size, function.optional_positionals.size, !function.rest_positionals.nil?,
           function.trailing_positionals.size, function.required_keywords.keys.sort,
           function.optional_keywords.keys.sort, !function.rest_keywords.nil?]
        end

        # Aligned `[label, sig_param, inline_param]` triples for two functions of the same shape.
        def parameter_pairs(sig_fn, inline_fn)
          positional_pairs(sig_fn, inline_fn) + keyword_pairs(sig_fn, inline_fn)
        end

        def positional_pairs(sig_fn, inline_fn)
          inline_leading = inline_fn.required_positionals + inline_fn.optional_positionals
          pairs = (sig_fn.required_positionals + sig_fn.optional_positionals).each_with_index.map do |param, i|
            ["parameter #{i + 1}", param, inline_leading[i]]
          end
          pairs << ["rest parameter", sig_fn.rest_positionals, inline_fn.rest_positionals] if sig_fn.rest_positionals
          sig_fn.trailing_positionals.each_with_index do |param, i|
            pairs << ["trailing parameter #{i + 1}", param, inline_fn.trailing_positionals[i]]
          end
          pairs
        end

        def keyword_pairs(sig_fn, inline_fn)
          inline_keywords = inline_fn.required_keywords.merge(inline_fn.optional_keywords)
          pairs = sig_fn.required_keywords.merge(sig_fn.optional_keywords).map do |name, param|
            ["keyword `#{name}:`", param, inline_keywords[name]]
          end
          pairs << ["keyword rest parameter", sig_fn.rest_keywords, inline_fn.rest_keywords] if sig_fn.rest_keywords
          pairs
        end

        # A shape difference is a contradiction only where no call can satisfy both: the positional arity
        # ranges are disjoint, or one side requires a keyword the other cannot accept.
        def shape_contradiction(sig_fn, inline_fn, prefix)
          sig_range = positional_range(sig_fn)
          inline_range = positional_range(inline_fn)
          if sig_range.last < inline_range.first || inline_range.last < sig_range.first
            return [:contradiction, "#{prefix}`sig/` accepts #{describe_range(sig_range)} positional argument(s) " \
                                    "and the inline annotation #{describe_range(inline_range)}"]
          end

          keyword = unacceptable_keyword(sig_fn, inline_fn) || unacceptable_keyword(inline_fn, sig_fn)
          return nil if keyword.nil?

          [:contradiction, "#{prefix}keyword `#{keyword}:` is required by one side and not accepted by the other"]
        end

        def positional_range(function)
          minimum = function.required_positionals.size + function.trailing_positionals.size
          maximum = function.rest_positionals ? Float::INFINITY : minimum + function.optional_positionals.size
          (minimum..maximum)
        end

        def describe_range(range)
          return range.first.to_s if range.first == range.last
          return "#{range.first} or more" if range.last == Float::INFINITY

          "#{range.first} to #{range.last}"
        end

        def unacceptable_keyword(requiring, other)
          return nil unless other.rest_keywords.nil?

          requiring.required_keywords.keys.find do |name|
            !other.required_keywords.key?(name) && !other.optional_keywords.key?(name)
          end
        end

        # One type position. The top spellings are the least precise answer; a position Rigor cannot
        # translate faithfully is undecided unless the two are spelled identically.
        def compare_slot(label, sig_slot, inline_slot)
          return [:equal, nil] if sig_slot == inline_slot

          sig_top = top_slot?(sig_slot)
          inline_top = top_slot?(inline_slot)
          return [:equal, nil] if sig_top && inline_top
          return [:inline, nil] if sig_top
          return [:signature, nil] if inline_top

          sig_type = slot_type(sig_slot)
          inline_type = slot_type(inline_slot)
          return [:undecided, "#{label} is a type Rigor cannot compare"] if sig_type.nil? || inline_type.nil?

          slot_verdict(label, sig_slot, inline_slot, sig_type.accepts(inline_type), inline_type.accepts(sig_type))
        end

        def slot_verdict(label, sig_slot, inline_slot, inline_fits, sig_fits)
          return [:equal, nil] if inline_fits.yes? && sig_fits.yes?
          return [:inline, nil] if inline_fits.yes?
          return [:signature, nil] if sig_fits.yes?

          unless inline_fits.no? && sig_fits.no?
            return [:undecided, "Rigor cannot tell whether the two #{label}s overlap"]
          end

          [:contradiction,
           "#{label} is `#{describe_slot(sig_slot)}` in `sig/` and `#{describe_slot(inline_slot)}` inline, " \
           "and neither is a subtype of the other"]
        end

        def top_slot?(slot)
          slot.override.nil? && TOP_SPELLINGS.any? { |klass| slot.rbs_type.is_a?(klass) }
        end

        def slot_type(slot)
          return slot.override if slot.override
          return nil unless faithful?(slot.rbs_type)

          translate(slot.rbs_type)
        end

        def describe_slot(slot)
          slot.override ? slot.override.describe(:short) : slot.rbs_type.to_s
        end

        # Whether the Rigor translation of `type` keeps everything a subtype answer could depend on.
        # `RbsTypeTranslator` reads an alias, an interface, `self`, `instance`, `class` and a type variable as
        # `untyped`, a proc as the bare `Proc` class, and an intersection as one of its members; comparing
        # those would let a lost detail decide which side binds.
        def faithful?(type)
          case type
          when *FAITHFUL_LEAVES then true
          when ::RBS::Types::ClassInstance then type.args.all? { |arg| faithful?(arg) }
          when ::RBS::Types::Optional then faithful?(type.type)
          when ::RBS::Types::Union, ::RBS::Types::Tuple then type.types.all? { |member| faithful?(member) }
          when ::RBS::Types::Record then (type.fields.values + type.optional_fields.values).all? { |v| faithful?(v) }
          else false
          end
        end

        def translate(type)
          Inference::RbsTypeTranslator.translate(type)
        rescue StandardError
          nil
        end

        # Folds per-position results into one member verdict: any contradiction wins, then any undecided
        # position, then the direction every precise position agrees on. Positions pointing both ways are
        # undecided — each side says something the other does not.
        def combine(results)
          contradiction = results.find { |outcome, _| outcome == :contradiction }
          return contradiction if contradiction

          undecided = results.find { |outcome, _| outcome == :undecided }
          return undecided if undecided

          outcomes = results.map(&:first)
          if outcomes.include?(:inline) && outcomes.include?(:signature)
            return [:undecided, "each declaration is more precise than the other in a different position"]
          end
          return [:inline, nil] if outcomes.include?(:inline)
          return [:signature, nil] if outcomes.include?(:signature)

          [:equal, nil]
        end

        # `[return_override, {param_name => override}]` read off the member's and its overloads' annotations
        # with `RbsExtended`'s own parsers, so a refinement means here what it means at a call site.
        def refinements_of(member)
          strings = member_annotation_strings(member).select { |string| refinement_directive?(string) }
          return [nil, {}.freeze] if strings.empty?

          return_override = strings.lazy.filter_map { |string| RbsExtended.parse_return_type_override(string) }.first
          params = strings.filter_map { |string| RbsExtended.parse_param_annotation(string) }
          [return_override, params.to_h { |override| [override.param_name, override.type] }]
        end

        def refinement_directive?(string)
          string.start_with?(RETURN_DIRECTIVE_PREFIX, PARAM_DIRECTIVE_PREFIX)
        end

        # Allocates only for a member that carries an annotation, which most do not.
        def member_annotation_strings(member)
          strings = nil
          if member.respond_to?(:annotations)
            Array(member.annotations).each do |annotation|
              (strings ||= []) << annotation.string
            end
          end
          if member.is_a?(::RBS::AST::Members::MethodDefinition)
            member.overloads.each do |overload|
              Array(overload.annotations).each { |annotation| (strings ||= []) << annotation.string }
            end
          end
          strings || NO_STRINGS
        end

        def refinement_conflicts_in(method_type, return_override, param_overrides)
          function = method_type.type
          conflicts = []
          if return_override && exceeds?(function.return_type, return_override)
            conflicts << "`rigor:v1:return: #{return_override.describe(:short)}` is outside the declared " \
                         "return type `#{function.return_type}`"
          end
          return conflicts if param_overrides.empty? || function.is_a?(::RBS::Types::UntypedFunction)

          each_named_param(function) do |param|
            override = param_overrides[param.name]
            next if override.nil? || !exceeds?(param.type, override)

            conflicts << "`rigor:v1:param: #{param.name} #{override.describe(:short)}` is outside the declared " \
                         "parameter type `#{param.type}`"
          end
          conflicts
        end

        def each_named_param(function, &)
          params = function.required_positionals + function.optional_positionals + function.trailing_positionals +
                   [function.rest_positionals, function.rest_keywords].compact +
                   function.required_keywords.values + function.optional_keywords.values
          params.select(&:name).each(&)
        end

        # A refinement exceeds its declared type when the declared type provably does not accept it. A top
        # spelling accepts everything, and a declared type Rigor cannot read faithfully proves nothing.
        def exceeds?(declared, refinement)
          return false if TOP_SPELLINGS.any? { |klass| declared.is_a?(klass) } || !faithful?(declared)

          declared_type = translate(declared)
          !declared_type.nil? && declared_type.accepts(refinement).no?
        end
      end
    end
  end
end
