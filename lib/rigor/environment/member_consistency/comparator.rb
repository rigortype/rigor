# frozen_string_literal: true

require "rbs"

require_relative "../../type"
require_relative "../../inference/acceptance"
require_relative "../../inference/rbs_type_translator"
require_relative "../../rbs_extended"

module Rigor
  class Environment
    module MemberConsistency
      # Compares two declarations of one member (ADR-112 WD5), and a member's refinements with its own
      # declared types. See {MemberConsistency} for the rule; this class holds the type work.
      #
      # A contradiction is reported only where it is PROVEN: no value, and no call, satisfies both sides.
      # Everything short of a proof is undecided. Three places carry that burden:
      #
      # - {#disjoint?} proves two types share no value. `accepts` answering `no` both ways is not such a
      #   proof (`Comparable` and `Enumerable` are both "no" and share values), so disjointness is read off
      #   exact values and loaded classes only: two classes neither of which is an ancestor of the other,
      #   or a literal outside a class. A module, an interface, a class the analyzer has not loaded, or a
      #   carrier with no class of its own proves nothing.
      # - {#faithful?} refuses a type position whose Rigor translation could mean something else: an alias,
      #   an interface, `self`, a type variable, a proc, and a relative class name the project itself could
      #   shadow (a relative `Data` inside `module App` may be `App::Data`).
      # - Overloads are paired by correspondence, never by position, and a member whose overloads do not
      #   pair one to one is undecided.
      class Comparator # rubocop:disable Metrics/ClassLength
        # A type position: the declared RBS type, and the `rigor:v1:` refinement that overrides it (or nil).
        Slot = Data.define(:rbs_type, :override)
        private_constant :Slot

        # The RBS leaf types whose Rigor translation loses nothing a precision comparison could depend on.
        FAITHFUL_LEAVES = [
          ::RBS::Types::Bases::Any, ::RBS::Types::Bases::Bool, ::RBS::Types::Bases::Nil,
          ::RBS::Types::Bases::Top, ::RBS::Types::Bases::Bottom, ::RBS::Types::Bases::Void,
          ::RBS::Types::Literal
        ].freeze
        private_constant :FAITHFUL_LEAVES

        # RBS's three spellings of the top type ("they are all equivalent for the type system" — rbs
        # `docs/syntax.md`). None says anything about the value, so each is the least precise answer a
        # position can give, and two of them are equal.
        TOP_SPELLINGS = [::RBS::Types::Bases::Any, ::RBS::Types::Bases::Top, ::RBS::Types::Bases::Void].freeze
        private_constant :TOP_SPELLINGS

        # Classes whose instances are exactly one value, read as that value so `bool` and `TrueClass`
        # compare as a union and its member rather than as two unrelated names.
        SINGLE_VALUE_CLASSES = { "TrueClass" => true, "FalseClass" => false, "NilClass" => nil }.freeze
        private_constant :SINGLE_VALUE_CLASSES

        EQUAL = [:equal, nil].freeze
        SIGNATURE_MORE_PRECISE = [:signature, nil].freeze
        CONSISTENT = %i[equal signature inline].freeze
        NO_STRINGS = [].freeze
        private_constant :EQUAL, :SIGNATURE_MORE_PRECISE, :CONSISTENT, :NO_STRINGS

        RETURN_DIRECTIVE_PREFIX = "rigor:v1:return:"
        PARAM_DIRECTIVE_PREFIX = "rigor:v1:param:"
        INFERRED_SIGNATURE_DIRECTIVE = RbsExtended::INFERRED_SIGNATURE_DIRECTIVE
        private_constant :RETURN_DIRECTIVE_PREFIX, :PARAM_DIRECTIVE_PREFIX, :INFERRED_SIGNATURE_DIRECTIVE

        # More overloads than this per member are left undecided rather than paired: the pairing compares
        # every overload with every other.
        PAIRING_LIMIT = 16
        private_constant :PAIRING_LIMIT

        # @param shadowable — the first `::` segment of every class / module name the project's own inputs
        #   declare. A relative class name starting with one of them may resolve inside an enclosing
        #   namespace, so it is not compared.
        def initialize(shadowable)
          @shadowable = shadowable
        end

        # @return `[outcome, detail]` — `outcome` is `:equal`, `:signature` (`sig/` is more precise),
        #   `:inline` (the inline side is more precise), `:contradiction` or `:undecided`; `detail` names the
        #   deciding position for the two reported outcomes and is nil otherwise.
        def compare(signature_member, inline_member, method_name)
          return EQUAL if same_declaration?(signature_member, inline_member)
          return SIGNATURE_MORE_PRECISE if inferred_signature?(inline_member)

          if signature_member.is_a?(::RBS::AST::Members::Alias) || inline_member.is_a?(::RBS::AST::Members::Alias)
            return compare_aliases(signature_member, inline_member)
          end

          compare_overloads(
            overloads_for(signature_member, method_name), overloads_for(inline_member, method_name),
            refinements_of(signature_member), refinements_of(inline_member)
          )
        end

        # The details of every member-level `rigor:v1:return:` / `rigor:v1:param:` refinement on `member`
        # that is provably disjoint from its own declared type in every overload it applies to. Only
        # member-level annotations count: `RBS::Definition::Method#annotations`, which call sites read, does
        # not carry an overload's own annotations, so the engine never honours those.
        def refinement_conflicts(member)
          return NO_STRINGS unless member_annotation_strings(member).any? { |string| refinement_directive?(string) }

          return_override, param_overrides = refinements_of(member)
          method_types = member_method_types(member)
          return NO_STRINGS if method_types.empty?

          conflicts = []
          conflicts << return_conflict(method_types, return_override) if return_override
          param_overrides.each { |name, override| conflicts << param_conflict(method_types, name, override) }
          conflicts.compact
        end

        # Every annotation string on the member and its overloads, in declaration order.
        def member_annotation_strings(member)
          strings = nil
          if member.respond_to?(:annotations)
            Array(member.annotations).each { |annotation| (strings ||= []) << annotation.string }
          end
          if member.is_a?(::RBS::AST::Members::MethodDefinition)
            member.overloads.each do |overload|
              Array(overload.annotations).each { |annotation| (strings ||= []) << annotation.string }
            end
          end
          strings || NO_STRINGS
        end

        def refinement_directive?(string)
          string.start_with?(RETURN_DIRECTIVE_PREFIX, PARAM_DIRECTIVE_PREFIX)
        end

        private

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

        # rbs-inline's skeleton for a `def` whose annotations asserted nothing about it (ADR-93 WD6,
        # `%a{rigor:v1:inferred-signature}`): no author wrote this inline side, so it has nothing to be
        # consistent or inconsistent with, and `sig/` binds without a word.
        def inferred_signature?(member)
          member_annotation_strings(member).include?(INFERRED_SIGNATURE_DIRECTIVE)
        end

        def compare_aliases(signature_member, inline_member)
          both = signature_member.is_a?(::RBS::AST::Members::Alias) && inline_member.is_a?(::RBS::AST::Members::Alias)
          return EQUAL if both && signature_member.old_name == inline_member.old_name

          [:undecided, "an alias cannot be compared with another declaration"]
        end

        # One overload each: compared directly, and the only shape where a contradiction can be reported. A
        # contradiction between two overload SETS would need every pairing refuted, and "these two overloads
        # disagree" says nothing when a third one covers the call; so several overloads either pair one to
        # one — each overload consistent with exactly one on the other side — or stay undecided.
        def compare_overloads(sig_types, inline_types, sig_refinements, inline_refinements)
          return [:undecided, "the two declare a different number of overloads"] if sig_types.size != inline_types.size
          if sig_types.size == 1
            return combine(compare_method_types(sig_types[0], inline_types[0], sig_refinements, inline_refinements))
          end
          return [:undecided, "too many overloads to pair"] if sig_types.size > PAIRING_LIMIT

          matrix = sig_types.map do |sig_type|
            inline_types.map do |inline_type|
              combine(compare_method_types(sig_type, inline_type, sig_refinements, inline_refinements))
            end
          end
          paired = unique_pairing(matrix, [:equal]) || unique_pairing(matrix, CONSISTENT)
          return [:undecided, "the overloads do not pair one to one"] if paired.nil?

          combine(paired)
        end

        # The verdicts of a one-to-one pairing in which every row has exactly one column whose outcome is in
        # `accepted`, all columns distinct; nil when there is no such pairing.
        def unique_pairing(matrix, accepted)
          columns = matrix.map do |row|
            candidates = row.each_index.select { |j| accepted.include?(row[j].first) }
            return nil unless candidates.size == 1

            candidates.first
          end
          return nil unless columns.uniq.size == columns.size

          columns.each_with_index.map { |j, i| matrix[i][j] }
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

        def compare_method_types(sig_type, inline_type, sig_refinements, inline_refinements)
          return [EQUAL] if sig_refinements == inline_refinements && sig_type == inline_type
          unless sig_type.type_params.empty? && inline_type.type_params.empty?
            return [[:undecided, "a generic method type"]]
          end

          compare_functions(sig_type.type, inline_type.type, sig_refinements, inline_refinements, "", block: false) +
            compare_blocks(sig_type.block, inline_type.block)
        end

        def compare_blocks(sig_block, inline_block)
          return [] if sig_block.nil? && inline_block.nil?
          return [[:undecided, "only one side declares a block"]] if sig_block.nil? || inline_block.nil?
          return [[:undecided, "the block is required on one side only"]] if sig_block.required != inline_block.required

          compare_functions(sig_block.type, inline_block.type, [nil, {}], [nil, {}], "block ", block: true)
        end

        def compare_functions(sig_fn, inline_fn, sig_refinements, inline_refinements, prefix, block:)
          results = compare_parameters(sig_fn, inline_fn, sig_refinements[1], inline_refinements[1], prefix, block)
          results << compare_slot(
            "#{prefix}return type",
            Slot.new(rbs_type: sig_fn.return_type, override: sig_refinements[0]),
            Slot.new(rbs_type: inline_fn.return_type, override: inline_refinements[0])
          )
          results
        end

        # `(?) -> T` declares nothing about its parameters, so the other side's parameter list is the more
        # precise one — or they are equal when both are untyped.
        def compare_parameters(sig_fn, inline_fn, sig_params, inline_params, prefix, block)
          sig_untyped = sig_fn.is_a?(::RBS::Types::UntypedFunction)
          inline_untyped = inline_fn.is_a?(::RBS::Types::UntypedFunction)
          return [] if sig_untyped && inline_untyped
          return [[:inline, nil]] if sig_untyped
          return [[:signature, nil]] if inline_untyped

          unless function_shape(sig_fn) == function_shape(inline_fn)
            return [(!block && shape_contradiction(sig_fn, inline_fn, prefix)) ||
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

        # A shape difference is a contradiction only where no call can satisfy both. Ruby passes keywords to
        # a method without keyword parameters as a trailing positional Hash, so the positional counts only
        # mean something when neither side takes keywords; and a keyword one side requires is refused by the
        # other only when the other has no positional parameter a Hash could land in and no `**rest`. A
        # block's parameters never contradict by count: a block is called with whatever its caller passes.
        def shape_contradiction(sig_fn, inline_fn, prefix)
          if keywordless?(sig_fn) && keywordless?(inline_fn)
            sig_range = positional_range(sig_fn)
            inline_range = positional_range(inline_fn)
            if sig_range.last < inline_range.first || inline_range.last < sig_range.first
              return [:contradiction, "#{prefix}`sig/` accepts #{describe_range(sig_range)} positional " \
                                      "argument(s) and the inline annotation #{describe_range(inline_range)}"]
            end
          end

          keyword = unacceptable_keyword(sig_fn, inline_fn) || unacceptable_keyword(inline_fn, sig_fn)
          return nil if keyword.nil?

          [:contradiction, "#{prefix}keyword `#{keyword}:` is required by one side and not accepted by the other"]
        end

        def keywordless?(function)
          function.required_keywords.empty? && function.optional_keywords.empty? && function.rest_keywords.nil?
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
          return nil unless other.rest_keywords.nil? && other.rest_positionals.nil?
          unless (other.required_positionals + other.optional_positionals + other.trailing_positionals).empty?
            return nil
          end

          requiring.required_keywords.keys.find do |name|
            !other.required_keywords.key?(name) && !other.optional_keywords.key?(name)
          end
        end

        # One type position. The top spellings are the least precise answer; a position Rigor cannot
        # translate faithfully is undecided unless the two are spelled identically.
        def compare_slot(label, sig_slot, inline_slot)
          return EQUAL if sig_slot == inline_slot

          sig_top = top_slot?(sig_slot)
          inline_top = top_slot?(inline_slot)
          return EQUAL if sig_top && inline_top
          return [:inline, nil] if sig_top
          return SIGNATURE_MORE_PRECISE if inline_top

          sig_type = slot_type(sig_slot)
          inline_type = slot_type(inline_slot)
          return [:undecided, "#{label} is a type Rigor cannot compare"] if sig_type.nil? || inline_type.nil?

          slot_verdict(label, sig_slot, inline_slot, sig_type, inline_type)
        end

        def slot_verdict(label, sig_slot, inline_slot, sig_type, inline_type)
          inline_fits = sig_type.accepts(inline_type).yes?
          sig_fits = inline_type.accepts(sig_type).yes?
          return EQUAL if inline_fits && sig_fits
          return [:inline, nil] if inline_fits
          return SIGNATURE_MORE_PRECISE if sig_fits
          return [:undecided, "Rigor cannot tell whether the two #{label}s overlap"] unless disjoint?(sig_type,
                                                                                                      inline_type)

          [:contradiction,
           "#{label} is `#{describe_slot(sig_slot)}` in `sig/` and `#{describe_slot(inline_slot)}` inline, " \
           "and no value is both"]
        end

        def top_slot?(slot)
          slot.override.nil? && TOP_SPELLINGS.any? { |klass| slot.rbs_type.is_a?(klass) }
        end

        def slot_type(slot)
          type = slot.override || (faithful?(slot.rbs_type) ? translate(slot.rbs_type) : nil)
          type && single_values(type)
        end

        # `TrueClass` / `FalseClass` / `NilClass` as the one value each holds, through a union.
        def single_values(type)
          case type
          when Type::Nominal
            return type unless type.type_args.empty? && SINGLE_VALUE_CLASSES.key?(type.class_name)

            Type::Combinator.constant_of(SINGLE_VALUE_CLASSES.fetch(type.class_name))
          when Type::Union then Type::Combinator.union(*type.members.map { |member| single_values(member) })
          else type
          end
        end

        def describe_slot(slot)
          slot.override ? slot.override.describe(:short) : slot.rbs_type.to_s
        end

        # Whether the Rigor translation of `type` keeps everything a subtype answer could depend on.
        # `RbsTypeTranslator` reads an alias, an interface, `self`, `instance`, `class` and a type variable as
        # `untyped`, a proc as the bare `Proc` class, and an intersection as one of its members; and it reads
        # a relative class name as a top-level one, which it is not when an enclosing namespace declares the
        # same name. Comparing any of those would let a lost detail decide which side binds, or report a
        # contradiction between two spellings of one class.
        def faithful?(type)
          case type
          when *FAITHFUL_LEAVES then true
          when ::RBS::Types::ClassInstance then faithful_name?(type.name) && type.args.all? { |arg| faithful?(arg) }
          when ::RBS::Types::ClassSingleton then faithful_name?(type.name)
          when ::RBS::Types::Optional then faithful?(type.type)
          when ::RBS::Types::Union, ::RBS::Types::Tuple then type.types.all? { |member| faithful?(member) }
          when ::RBS::Types::Record then (type.fields.values + type.optional_fields.values).all? { |v| faithful?(v) }
          else false
          end
        end

        # An absolute name means what it says. A relative one resolves outward from the member's class, so it
        # is read as top-level only when the project declares no class or module whose name starts with the
        # same segment — which is also what makes the `sig/` and the inline spelling of it comparable.
        def faithful_name?(name)
          return true if name.absolute?

          head = name.namespace.path.first || name.name
          !@shadowable.include?(head.to_s)
        end

        def translate(type)
          Inference::RbsTypeTranslator.translate(type)
        rescue StandardError
          nil
        end

        # Whether `left` and `right` provably share no value: every pairing of their members is two distinct
        # exact values, a value outside a class, or two loaded classes neither of which is an ancestor of the
        # other. Anything else — a module, an unloaded or project class, a carrier without an exact class — is
        # left unproven, so the answer is false.
        def disjoint?(left, right)
          left_atoms = atoms(left)
          right_atoms = atoms(right)
          return false if left_atoms.nil? || right_atoms.nil?

          left_atoms.all? { |a| right_atoms.all? { |b| disjoint_atoms?(a, b) } }
        end

        # `[:value, v]` or `[:class, Class]` per union member, or nil when a member has neither.
        def atoms(type)
          members = type.is_a?(Type::Union) ? type.members : [type]
          result = members.map { |member| atom(member) }
          result.include?(nil) ? nil : result
        end

        def atom(type)
          case type
          when Type::Constant then [:value, type.value]
          when Type::Nominal then class_atom(type.class_name)
          when Type::Refined, Type::Difference then atom(type.base)
          when Type::IntegerRange then [:class, ::Integer]
          when Type::FloatRange then [:class, ::Float]
          when Type::Tuple then [:class, ::Array]
          when Type::HashShape then [:class, ::Hash]
          end
        end

        # A loaded CLASS only: a module can be mixed into any class, so it proves nothing.
        def class_atom(name)
          loaded = Inference::Acceptance.loaded_module(name)
          loaded.instance_of?(::Class) ? [:class, loaded] : nil
        end

        def disjoint_atoms?(left, right)
          case [left[0], right[0]]
          when %i[value value] then !left[1].eql?(right[1])
          when %i[value class] then !left[1].is_a?(right[1])
          when %i[class value] then !right[1].is_a?(left[1])
          else (left[1] <= right[1]).nil? # `Module#<=` answers nil for two unrelated classes
          end
        end

        # Folds per-position results into one verdict: any contradiction wins, then any undecided position,
        # then the direction every precise position agrees on. Positions pointing both ways are undecided —
        # each side says something the other does not.
        def combine(results)
          contradiction = results.find { |outcome, _| outcome == :contradiction }
          return contradiction if contradiction

          undecided = results.find { |outcome, _| outcome == :undecided }
          return undecided if undecided

          directions = results.map(&:first)
          if directions.include?(:inline) && directions.include?(:signature)
            return [:undecided, "each declaration is more precise than the other in a different position"]
          end
          return [:inline, nil] if directions.include?(:inline)
          return SIGNATURE_MORE_PRECISE if directions.include?(:signature)

          EQUAL
        end

        # `[return_override, {param_name => override}]` read off the MEMBER's annotations — the ones
        # `RBS::Definition::Method#annotations` carries and call sites honour — with `RbsExtended`'s own
        # parsers, so a refinement means here what it means at a call site.
        def refinements_of(member)
          strings = Array(member.annotations).map(&:string).select { |string| refinement_directive?(string) }
          return [nil, {}.freeze] if strings.empty?

          return_override = strings.lazy.filter_map { |string| RbsExtended.parse_return_type_override(string) }.first
          params = strings.filter_map { |string| RbsExtended.parse_param_annotation(string) }
          [return_override, params.to_h { |override| [override.param_name, override.type] }]
        end

        def return_conflict(method_types, override)
          declared = method_types.map { |method_type| method_type.type.return_type }
          return nil unless declared.all? { |type| exceeds?(type, override) }

          "`rigor:v1:return: #{override.describe(:short)}` is disjoint from the declared return type " \
            "`#{declared.map(&:to_s).uniq.join('` / `')}`"
        end

        def param_conflict(method_types, name, override)
          declared = method_types.flat_map do |method_type|
            function = method_type.type
            function.is_a?(::RBS::Types::UntypedFunction) ? [] : named_params(function, name)
          end
          return nil if declared.empty? || !declared.all? { |param| exceeds?(param.type, override) }

          "`rigor:v1:param: #{name} #{override.describe(:short)}` is disjoint from the declared parameter type " \
            "`#{declared.map { |param| param.type.to_s }.uniq.join('` / `')}`"
        end

        def named_params(function, name)
          (function.required_positionals + function.optional_positionals + function.trailing_positionals +
            [function.rest_positionals, function.rest_keywords].compact +
            function.required_keywords.values + function.optional_keywords.values).select { |p| p.name == name }
        end

        # A refinement exceeds its declared type when the two provably share no value. A top spelling holds
        # every value, and a declared type Rigor cannot read faithfully proves nothing.
        def exceeds?(declared, refinement)
          return false if TOP_SPELLINGS.any? { |klass| declared.is_a?(klass) } || !faithful?(declared)

          declared_type = translate(declared)
          !declared_type.nil? && disjoint?(single_values(declared_type), single_values(refinement))
        end
      end
    end
  end
end
