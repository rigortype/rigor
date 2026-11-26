# frozen_string_literal: true

require_relative "../../type"
require_relative "../string_mutation"
require_relative "../unknown_store_widening"
require_relative "mutated_element_census"

module Rigor
  module Inference
    module ScopeIndexer
      # The widening of the carriers a file mutates in place (#540), moved out of `scope_indexer.rb` whole (ADR-116
      # WD9, #3400). {LiteralReceiverMutations} names the constants and class variables a call mutates, and the
      # elements a call mutates through a read of one; the functions here give each such entry of a table the type
      # its readers may still rely on.
      #
      # Four functions are public, because another file calls each. `ScopeIndexer.index` calls
      # {.widen_mutated_constants} and {.widen_mutated_cvars} on the two tables it builds, and {ConstantIvarValue}
      # calls the first on the constant table it builds for the ivar census. {MutatedElementCensus}, which
      # {.widen_mutated_elements} asks for the element a chain of reads reaches, asks {.census_mutated_type} and
      # {.census_unpinned_content} back for the type of that element and of a nominal on the way. The other three
      # functions are private steps of those, and the three constants are the module's own.
      #
      # It calls nothing left in `scope_indexer.rb` and reads none of the indexer's constants. `scope_indexer.rb`
      # requires this file, and this file does not require it back, so it loads and answers alone.
      module MutatedCarrierWidening
        module_function

        NO_ELEMENT_MUTATIONS = Set.new.freeze
        NO_CVAR_ELEMENT_MUTATIONS = {}.freeze

        # `mutated_elements` — the `[name, steps]` pairs of an element mutation (#3243), widened after every whole-name
        # mutation and shallowest first, so the table is the same whichever order the program spells them in.
        def widen_mutated_constants(accumulator, mutated_names, mutated_elements = NO_ELEMENT_MUTATIONS)
          return accumulator if mutated_names.empty? && mutated_elements.empty?

          widened = accumulator.dup
          mutated_names.each do |name|
            existing = widened[name]
            next if existing.nil?

            widened[name] = census_mutated_type(existing)
          end
          widen_mutated_elements(widened, mutated_elements).freeze
        end

        def widen_mutated_cvars(accumulator, mutated_by_class, elements_by_class = NO_CVAR_ELEMENT_MUTATIONS)
          return accumulator if mutated_by_class.empty? && elements_by_class.empty?

          widened = accumulator.dup
          (mutated_by_class.keys | elements_by_class.keys).each do |class_name|
            table = widened[class_name]
            next if table.nil?

            updated = table.dup
            mutated_by_class.fetch(class_name, NO_ELEMENT_MUTATIONS).each do |cvar|
              existing = updated[cvar]
              next if existing.nil?

              updated[cvar] = census_mutated_type(existing)
            end
            widened[class_name] =
              widen_mutated_elements(updated, elements_by_class.fetch(class_name, NO_ELEMENT_MUTATIONS)).freeze
          end
          widened.freeze
        end

        # `table` with the element each `[name, steps]` pair reaches widened ({MutatedElementCensus.widen}), as a copy;
        # `table` itself when no pair reaches anything.
        def widen_mutated_elements(table, mutated_elements)
          return table if mutated_elements.empty?

          MutatedElementCensus.ordered(mutated_elements).reduce(table) do |current, (name, steps)|
            existing = current[name]
            updated = existing && MutatedElementCensus.widen(existing, steps)
            updated ? current.merge(name => updated) : current
          end
        end

        # The type a mutated constant or class variable is read as. The census records the NAME a call mutated and not
        # the call, so it cannot say what was stored, and `Dynamic` alone does not say it either: a read resolves
        # through the static facet's RBS projection, where a closed `HashShape` answers its known values for any key, a
        # `Tuple` its known elements for any index and an `Array[1 | 2]` `1 | 2`. `H = { a: 1 }; H.default = 0` read
        # `H[:b]` as `1`, and `T = { a: 1 }; T[:b] = 2` read `T[:b]` as `1` too, so `== 0` / `== 2` folded
        # always-falsey.
        #
        # Each carrier member of the facet therefore stops claiming its contents are complete. A literal shape floors to
        # `Hash[untyped, untyped]` and a tuple to `Array[untyped]`, as ADR-58's class-level ivar census floors an ivar
        # seed a method stores into (#1297). Unlike that census, a shape only a lookup mutator (`default=`) touched
        # floors too, since the census does not record the method, so its present-key reads are lost as well (#1421).
        # Keeping the literal's known values beside a `Dynamic[top]` arm left every read carrying them, and every key's
        # at that, since the projection is not keyed, so `STATUS[:name]` answered `false | nil | Dynamic[top]` and a
        # method declared `-> String` returning it drew `def.return-type-mismatch` although a sibling method could store
        # anything there. An `Array` / `Hash` nominal with a value-pinned type argument gains the arm on every type
        # argument, as the unknown-store seam gives it. A class-level nominal (`Hash.new(0)`'s
        # `Hash[Dynamic[top], Integer]`) is left alone: a store of the same class keeps it true, and the arm would
        # silence `COUNTS[k].upcase`. An entry already `Dynamic` is unpinned through its facet, so a carrier an RBS
        # overload join wrapped is not left pinned.
        def census_mutated_type(type)
          type = type.static_facet if type.is_a?(Type::Dynamic)
          members = type.is_a?(Type::Union) ? type.members : [type]
          Type::Combinator.dynamic(Type::Combinator.union(*members.map { |member| census_unpinned_carrier(member) }))
        end

        # A `Difference` / `Refined` member drops to its unpinned base: a mutation can falsify the removed value or the
        # refinement as well (`clear` empties a `non-empty-array`).
        #
        # Issue #3243 — a String literal floors to `String`, since the mutation can rewrite it (`S << "b"`), and an
        # `Array` / `Hash` nominal first unpins the literal carriers its type arguments hold
        # ({.census_unpinned_content}): `[[1]].shuffle`'s `Array[[1]]` is not value-pinned at the top, yet
        # `SHUF[0].last` read the stale `1`.
        def census_unpinned_carrier(member)
          case member
          when Type::HashShape
            Type::Combinator.nominal_of("Hash", type_args: [Type::Combinator.untyped, Type::Combinator.untyped])
          when Type::Tuple then Type::Combinator.nominal_of("Array", type_args: [Type::Combinator.untyped])
          when Type::Constant then StringMutation.constant?(member) ? Type::Combinator.nominal_of("String") : member
          when Type::Nominal
            # The pin is tested BEFORE the content is unpinned, and on the original member: unpinning floors a
            # literal type argument to its class (`Array["a"]` to `Array[String]`), which is a class-level argument
            # and so not value-pinned, and the `Dynamic[top]` arm never arrived. `NS = ["a"].shuffle` with a method
            # running `NS << 1` then kept claiming every element is a `String`, so `NS[1].odd?` — correct Ruby on the
            # Integer that method stores — drew `call.undefined-method`. Whether the carrier held anything
            # value-pinned at any depth is the question, and only the un-floored member can answer it.
            pinned = UnknownStoreWidening.value_pinned_collection?(member)
            member = census_unpinned_content(member)
            pinned ? UnknownStoreWidening.gradual_content(member) : member
          when Type::Difference, Type::Refined then census_unpinned_carrier(member.base)
          else member
          end
        end

        CENSUS_CONTENT_CLASSES = %w[Array Hash].freeze

        # An `Array` / `Hash` nominal with each literal carrier its type arguments hold, at any depth, unpinned as
        # {.census_unpinned_carrier} unpins a member — `Array[[1]]` to `Array[Array[untyped]]` — and every other
        # argument (`Hash.new(0)`'s `Dynamic[top]` and `Integer`) left as it is. Answers `nominal` itself when nothing
        # in it is such a carrier.
        def census_unpinned_content(nominal)
          return nominal unless CENSUS_CONTENT_CLASSES.include?(nominal.class_name) && !nominal.type_args.empty?

          args = nominal.type_args.map { |arg| census_unpinned_argument(arg) }
          return nominal if args.each_with_index.all? { |arg, index| arg.equal?(nominal.type_args[index]) }

          Type::Combinator.nominal_of(nominal.class_name, type_args: args)
        end

        def census_unpinned_argument(arg)
          case arg
          when Type::Tuple, Type::HashShape then census_unpinned_carrier(arg)
          when Type::Constant then StringMutation.constant?(arg) ? Type::Combinator.nominal_of("String") : arg
          when Type::Nominal then census_unpinned_content(arg)
          when Type::Union
            members = arg.members.map { |member| census_unpinned_argument(member) }
            members.each_with_index.all? { |member, index| member.equal?(arg.members[index]) } ? arg : Type::Combinator.union(*members)
          else arg
          end
        end

        private_class_method :widen_mutated_elements, :census_unpinned_carrier, :census_unpinned_argument
      end
    end
  end
end
