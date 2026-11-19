# frozen_string_literal: true

require_relative "../../type"
require_relative "../anonymous_meta_class"
require_relative "../mutation_widening"
require_relative "argument_nodes"
require_relative "declared_constructor"
require_relative "set_folding"

module Rigor
  module Inference
    module MethodDispatcher
      # The meta-introspection tier: `x.class` on a receiver of known identity, and `Singleton[X].new` with its
      # curated constructor lifts (`Array`, `Range`, `Set`, `Hash`, `Regexp`, `Date`, `Struct`, `Class.new`, the
      # scalar-constant classes). It is the first of `MethodDispatcher`'s `PRECISE_TIERS_HEAD`, behind the `Data` and
      # `Struct` value tiers, whose receivers `meta_new` would otherwise answer as a bare `Nominal`.
      module MetaIntrospection # rubocop:disable Metrics/ModuleLength
        module_function

        # Slice 7 phase 8 — meta-introspection shortcuts. The default `Object#class` RBS return
        # type is `Class`, but for a receiver of known nominal identity we can do better:
        # `instance_of(Foo).class` is `Singleton[Foo]` (the class object itself), which downstream
        # dispatch uses to resolve `self.class.some_class_method`. The same logic answers
        # `Foo.class` as `Singleton[Class]` (deliberate; calling `.class` on a class object yields
        # `Class`, the metaclass). We also special-case `is_a?`-adjacent calls and the trivial
        # `instance_of?(self)` later as the rule catalogue grows; today `class` and `new` are handled.
        def try_dispatch(context)
          receiver_type = context.receiver
          method_name = context.method_name
          arg_types = context.args
          case method_name
          when :class then meta_class(receiver_type, context.environment)
          when :new then meta_new(receiver_type, arg_types, context)
          end
        end

        def meta_class(receiver_type, environment = nil)
          case receiver_type
          when Type::Nominal
            # An instance of module `M` is an instance of some class that includes `M`, never of `M`
            # itself: `self.class` in `M`'s instance method is that includer, which no RBS type names.
            # `Dynamic[Class]` keeps the surface every class shares (`name`, `ancestors`) and answers
            # nothing for the includer's own singleton methods.
            if environment&.rbs_module?(receiver_type.class_name)
              return Type::Combinator.dynamic(Type::Combinator.nominal_of("Class"))
            end

            Type::Combinator.singleton_of(receiver_type.class_name)
          when Type::Constant then constant_metaclass(receiver_type.value)
          end
        end

        # `Singleton[Foo].new` returns `Nominal[Foo]` (a fresh instance), regardless of whether Foo
        # is in RBS. This short-circuits the Class.new generic-`instance` plumbing for user
        # classes, so a discovered-class `ScanAccumulator.new` types as
        # `Nominal[ScanAccumulator]` rather than `Class`.
        #
        # v0.0.7 — for the curated set of immutable scalar-shaped classes that
        # `Type::Constant::SCALAR_CLASSES` accepts (today: `Pathname`), `.new(Constant<…>)` lifts
        # to a `Constant<…>` carrier so downstream method calls fold through the standard catalog
        # tier.
        def meta_new(receiver_type, arg_types = [], context = nil)
          return nil unless receiver_type.is_a?(Type::Singleton)

          constant_lift = constant_constructor_lift(receiver_type.class_name, arg_types)
          return constant_lift if constant_lift

          array_lift = array_new_lift(receiver_type.class_name, arg_types, context&.block_type)
          return array_lift if array_lift

          range_lift = range_new_lift(receiver_type.class_name, arg_types)
          return range_lift if range_lift

          set_lift = set_new_lift(receiver_type.class_name, arg_types, context)
          return set_lift if set_lift

          hash_lift = hash_new_lift(receiver_type.class_name, arg_types, context&.call_node)
          return hash_lift if hash_lift

          regexp_lift = regexp_new_lift(receiver_type.class_name, arg_types)
          return regexp_lift if regexp_lift

          date_lift = date_new_lift(receiver_type.class_name, arg_types)
          return date_lift if date_lift

          struct_new_lift = struct_new_lift(receiver_type.class_name, arg_types)
          return struct_new_lift if struct_new_lift

          class_new_lift = class_new_lift(receiver_type.class_name, arg_types, context)
          return class_new_lift if class_new_lift

          declared_or_nominal(receiver_type.class_name, context)
        end

        # Issue #2884 — the `meta_new` tail: a declared `def self.new` ({DeclaredConstructor}), else `Nominal[X]`.
        def declared_or_nominal(class_name, context)
          declared = context && DeclaredConstructor.try_dispatch(class_name, context)
          declared || Type::Combinator.nominal_of(class_name)
        end

        # `Struct.new(:a, :b)` synthesises an anonymous Struct *subclass* (a class object), not a
        # Struct *instance* — so the chained idiom `Struct.new(:a, :b).new(1, 2)` must resolve
        # `.new` again on a class-like carrier. The constant-bound form (`S = Struct.new(:a);
        # S.new(1)`) already records `Singleton[S]` via `ScopeIndexer#record_meta_new_constant?`;
        # this lift gives the *chained* (anonymous) position the same class-like carrier so the
        # trailing `.new` dispatches instead of firing a spurious `undefined method 'new' for
        # Struct`.
        #
        # The disambiguation mirrors `ScopeIndexer#struct_new_call?`: a call whose positionals are
        # all `Constant<Symbol>` literals is a member-list class definition → `Singleton[Struct]`.
        # The following `AnonStruct.new(1, 2)` carries non-symbol args, so it falls through this
        # gate to `Nominal[Struct]` (a fresh instance) via the `meta_new` tail. ADR-48 deferred full
        # Struct *value* folding (member-reader precision) on mutability grounds; this is the
        # narrower `.new`-dispatch-only fix and contributes no member layout, so `instance.a` stays
        # at its RBS/Dynamic type.
        def struct_new_lift(class_name, arg_types)
          return nil unless class_name == "Struct"

          positional = arg_types.grep_v(Type::HashShape)
          return nil if positional.empty?
          return nil unless positional.all? { |t| t.is_a?(Type::Constant) && t.value.is_a?(Symbol) }

          Type::Combinator.singleton_of("Struct")
        end

        # `Class.new` and `Class.new(Parent)` create a brand-new anonymous class. Statically that
        # class is representable as the parent's singleton type — its singleton-method surface is
        # the parent's (plus whatever the block defines, which we do not statically track here),
        # so `Singleton[Parent]` lets downstream `klass.some_class_method` resolve. No parent →
        # `singleton(Object)` (or the block's anonymous class, #319 below). Anything else (dynamic parent, more
        # than one positional, …) falls back to `Nominal[Class]` via the surrounding `meta_new` tail.
        # #319 — a `Class.new do ... end` with no parent is NOT `Object`: the block body is a class body, so the
        # class owns whatever that body defines. Answering `Singleton[Object]` handed the call site `Object`'s
        # zero-arity `new` and `Object`'s method surface, so an `initialize(bucket)` written right there produced
        # `wrong number of arguments ... (given 1, expected 0)` on code Ruby runs happily. `ScopeIndexer` registers
        # the body's methods under the call site's anonymous name; return that name so the lookups reach them.
        #
        # Scoped to the parentless form on purpose. `Class.new(Parent) { ... }` keeps `Singleton[Parent]`: the
        # anonymous name would have to carry the full ancestor chain for `Parent`'s own surface to stay reachable,
        # and the parentless case is where the false positive lives.
        def class_new_lift(class_name, arg_types, context = nil)
          return nil unless class_name == "Class"

          if arg_types.empty?
            anonymous = anonymous_class_new_name(context)
            return Type::Combinator.singleton_of(anonymous || "Object")
          end
          return nil unless arg_types.size == 1

          parent = arg_types.first
          factory_parent = parent.is_a?(Type::StructClass) || parent.is_a?(Type::DataClass)
          return nil if factory_parent && context&.call_node&.block
          return parent if parent.is_a?(Type::Singleton) || factory_parent

          nil
        end

        # The synthetic name `ScopeIndexer` keyed this call site's block body by, or nil when the context carries no
        # call node (internal dispatcher callers) or the call has no block. The source path is passed through
        # verbatim — including when it is nil, which is exactly what `ScopeIndexer` saw for the same file — so the
        # two passes derive the same name whether or not the caller supplied a path.
        def anonymous_class_new_name(context)
          return nil if context.nil?

          AnonymousMetaClass.name_for(context.call_node, context.scope&.source_path)
        end

        # ADR-15 Phase 4b.x — `Ractor.make_shareable` on both the outer Hash and each lambda value.
        # A plain `.freeze` leaves the Procs unshareable; reading `CONSTANT_CONSTRUCTORS[class]`
        # from a worker Ractor would raise `Ractor::IsolationError`, which the `rescue
        # StandardError` in `constant_constructor_lift` silently swallows — `meta_new` then falls
        # back to `Nominal[Pathname]` in pool mode while sequential builds the `Constant<Pathname>`
        # lift. The divergence surfaces downstream as a spurious `call.argument-type-mismatch`
        # (sequential's `CheckRules::ArgumentType.diagnostic` short-circuits on Constant<Pathname> because
        # Pathname is not in its CONSTANT_CLASSES table; pool's Nominal[Pathname] doesn't
        # short-circuit). Surfaced on GitLab FOSS via `lib/gitlab/mail_room.rb:17`.
        CONSTANT_CONSTRUCTORS = Ractor.make_shareable({
                                                        "Pathname" => Ractor.make_shareable(lambda { |arg|
                                                                                              Pathname.new(arg)
                                                                                            })
                                                      })
        private_constant :CONSTANT_CONSTRUCTORS

        def constant_constructor_lift(class_name, arg_types)
          builder = CONSTANT_CONSTRUCTORS[class_name]
          return nil if builder.nil?
          return nil unless arg_types.size == 1

          arg = arg_types.first
          return nil unless arg.is_a?(Type::Constant) && arg.value.is_a?(String)

          result = builder.call(arg.value)
          Type::Combinator.constant_of(result)
        rescue StandardError
          nil
        end

        # `Array.new(n, value)` and `Array.new(n)` (no value, default `nil`) lift to a per-position
        # `Tuple[…]` when `n` is a small `Constant<Integer>`. Cap at `ARRAY_NEW_TUPLE_LIMIT` (16)
        # so a `Array.new(1_000_000)` does not balloon the carrier; oversize calls fall through to
        # the element-parameter seed below.
        #
        # #317 — `Array.new(n) { |i| ... }` fills every slot from the BLOCK's return type instead
        # of the two-arg `(n, default_value)` overload's `nil` fill. The block and the trailing
        # `default_value` positional are mutually exclusive per `Array#initialize`'s RBS overload
        # set (`(int size, ?E default_value) -> void` vs `(int size) { (Integer index) -> E } ->
        # void`), so a block present at the call site always wins over any (illegal, but tolerated
        # rather than rejected here) second positional.
        ARRAY_NEW_TUPLE_LIMIT = 16
        private_constant :ARRAY_NEW_TUPLE_LIMIT

        def array_new_lift(class_name, arg_types, block_type = nil)
          return nil unless class_name == "Array"
          return nil if arg_types.empty? || arg_types.size > 2

          size = array_new_size(arg_types.first)
          if size && !size.negative? && size <= ARRAY_NEW_TUPLE_LIMIT
            return Type::Combinator.tuple_of(*Array.new(size, block_type || array_new_fill(arg_types[1])))
          end

          array_new_seed(arg_types, block_type)
        end

        # The carrier for a constructor whose size is not a small literal — `Array.new(n)`,
        # `Array.new(n, v)`, `Array.new(n) { … }`.
        #
        # This must never be a BARE `Array`. A nominal with no type argument carries no element
        # arm, and the ADR-56 block/loop seams read exactly that as an ELEMENTLESS seed — a fresh
        # accumulator whose every store the seam saw — so they CLOSE the carrier over the block's
        # own stores. `acc = Array.new(n); [1].each { acc.push(1) }` then read `Array[1]` for an
        # array whose other `n` slots hold `nil`, and `acc = Array.new(n, "x")` read `Array[1]` and
        # drew `undefined method 'upcase'` on the correct `acc.first.upcase` (issue #615). Handing
        # the seams a real element arm is what puts the constructor under the #586 rule, which
        # keeps every seed arm through the join.
        #
        # The element itself is the fill value's / block result's type, value-pin widened for the
        # reason `hash_new_lift` widens its default: the slots are rewritten over the array's
        # lifetime, so pinning the parameter to the literal would let a later `a[i] == "x"`
        # constant-fold.
        #
        # **The no-fill form seeds the GRADUAL element, not `nil`.** `Array.new(n)` really does put
        # a `nil` in every slot, but a `Nominal` seed gets DECLARED-carrier semantics downstream:
        # the #586 join keeps a seed arm forever, and `MutationWidening#widen_for_mutator` declines
        # a `Nominal` outright, so no whole-array rewrite — `[]=`, `fill`, `map!`, `replace`,
        # `concat` — can ever retract it. The placeholder would become a permanent nil possibility
        # over the allocate-then-fill idiom that is the whole point of the constructor:
        #
        #     dp = Array.new(xs.size); dp[0] = 1
        #     (1...n).each { |i| dp[i] = dp[i - 1] + xs[i] }   # `undefined method '+' for nil`
        #
        #     buf = Array.new(256); 256.times { |i| buf[i] = i.to_s }
        #     buf.each { |c| c.upcase }                        # possible nil receiver
        #
        # Both are correct Ruby, and both went from quiet to an ERROR on the `nil` seed. The true
        # positive the `nil` would buy — `Array.new(n).first.upcase` on an array nothing ever wrote
        # — is not worth the dominant idiom, so the no-fill form stays gradual whatever the size
        # argument reads as. (That also happens to absorb Ruby's array-convertible COPY overload:
        # `Array.new([1, 2])` is `[1, 2]`, not two nils.)
        def array_new_seed(arg_types, block_type)
          fill = block_type || arg_types[1]
          return array_seed_of(Type::Combinator.untyped) if fill.nil?

          element = array_new_element(fill)
          # `Array.new(n, nil)` is the same allocate-then-fill idiom as `Array.new(n)`, spelled with the
          # placeholder made explicit — concurrent-ruby writes `@Resolutions = ::Array.new(count, nil)` and
          # fills it by index. A nil-only element would be a PERMANENT nil arm (a Nominal carrier's element is
          # never widened by a later `[]=` / `fill` / `replace`), so every read of a filled slot would draw
          # `undefined method '…' for nil` on correct code. Same trade as the no-fill form above: the seam
          # needs an arm, not a precise one.
          element = Type::Combinator.untyped if nil_only_element?(element)
          array_seed_of(element)
        end

        # Whether the widened fill leaves nothing but `nil` behind — see {#array_new_seed}.
        def nil_only_element?(element)
          members = element.is_a?(Type::Union) ? element.members : [element]
          members.all? do |member|
            (member.is_a?(Type::Constant) && member.value.nil?) ||
              (member.is_a?(Type::Nominal) && member.class_name == "NilClass")
          end
        end

        def array_seed_of(element)
          Type::Combinator.nominal_of("Array", type_args: [element])
        end

        # A fill / block result as an element PARAMETER. Value pinning is dropped, and a literal
        # container widens to its nominal: `Array.new(n) { [] }` builds n INDEPENDENT arrays that
        # the program then appends to, and `Array[Tuple[]]` claims every one of them stays empty —
        # the adjacency-list idiom would read `adj[i].first` as `nil`. Both conversions go through
        # {MutationWidening}'s own helpers, the single owner of "literal container → parameterised
        # nominal" that `MemberShapeProjection` already borrows.
        #
        # The walk is **recursive**, through `Union` members and through a container's own elements /
        # values alike. Every one of those positions is a fresh object per constructed slot that the
        # program goes on to mutate, so stopping at the outermost level only moved the wrong-precise
        # answer one level in: `a = Array.new(n) { [[1]] }; a[0][0] << 5` left `Array[Array[[1]]]`
        # and folded `a[0][0].last == 5` always-falsey on correct code. Judging a `Union` wholesale
        # was the same defect one axis over — `Array.new(n) { flag ? [1] : [2] }` kept both arms as
        # fixed-arity tuples.
        #
        # `depth` is defensive only. A `Type` carrier is an immutable value object assembled
        # bottom-up (`Tuple.new(elements)`, `HashShape.new(pairs)`), so it cannot contain itself and
        # this walk is bounded by the source literal's own nesting; the cap costs nothing on any
        # literal a person writes and stops a malformed carrier from recursing forever.
        ARRAY_NEW_FILL_DEPTH_LIMIT = 8
        private_constant :ARRAY_NEW_FILL_DEPTH_LIMIT

        def array_new_element(type, depth = 0)
          return Type::Combinator.untyped if depth > ARRAY_NEW_FILL_DEPTH_LIMIT

          case type
          when Type::Tuple then MutationWidening.widen_tuple(recursed_tuple(type, depth))
          when Type::HashShape then MutationWidening.widen_hash_shape(recursed_hash_shape(type, depth))
          when Type::Union then Type::Combinator.union(*type.members.map { |m| array_new_element(m, depth + 1) })
          else Type::Combinator.widen_value_pinned(type)
          end
        end

        # The same tuple / hash shape with every element / value already widened, so the
        # {MutationWidening} helper that consumes it sees nominals where the literal had pins. The
        # rebuilt carrier is a throwaway argument — never surfaced — and the helpers read only
        # `elements` / `pairs`, so no policy field rides on it.
        def recursed_tuple(type, depth)
          Type::Combinator.tuple_of(*type.elements.map { |e| array_new_element(e, depth + 1) })
        end

        def recursed_hash_shape(type, depth)
          Type::Combinator.hash_shape_of(
            type.pairs.transform_values { |v| array_new_element(v, depth + 1) }
          )
        end

        def array_new_size(type)
          return nil unless type.is_a?(Type::Constant) && type.value.is_a?(Integer)

          type.value
        end

        def array_new_fill(type)
          return Type::Combinator.constant_of(nil) if type.nil?

          type
        end

        # `Hash.new(default)` — lifts the default value's type into the Hash's value parameter so
        # a subsequent `h[k]` read surfaces the default type rather than `Dynamic[top]`. The
        # common counter idiom `h = Hash.new(0); h[k] += 1` then types the read as `Integer`. The
        # key parameter is left `untyped` (the default carrier imposes no key constraint), so
        # reads of any key resolve through the value parameter. A value-pinned `Constant` default
        # (`0`) is widened to its nominal (`Integer`): the hash's values mutate over its lifetime,
        # so pinning the parameter to the literal would be unsound for the aggregate.
        #
        # Only the single-argument default form folds. The zero-arg (`Hash.new`) and the block
        # form (`Hash.new { |h, k| … }`) keep the bare `Nominal[Hash]` answer — the block's value
        # type is not available at this `:new` dispatch site, and conservatively leaving the read
        # as today's behaviour is precision-additive.
        #
        # Issue #1812 — a brace-less keyword hash is `Hash#initialize`'s `capacity:` keyword, not the
        # default (`Hash.new(capacity: 10).default` is `nil`), so it is dropped before counting the
        # positionals. A braced hash (`Hash.new({ capacity: 10 })`) is a positional and stays the default.
        def hash_new_lift(class_name, arg_types, call_node = nil)
          return nil unless class_name == "Hash"

          arg_types = hash_new_positionals(arg_types, call_node)
          return nil unless arg_types&.size == 1

          default = arg_types.first
          return nil if default.nil?

          value = Type::Combinator.widen_value_pinned(default)
          Type::Combinator.nominal_of("Hash", type_args: [Type::Combinator.untyped, value])
        end

        # `Hash.new`'s positional argument types: `arg_types` without a trailing brace-less keyword hash. A literal
        # send (`Hash.send(:new, capacity: 1)`) dispatches with the outer call node, whose arguments are the
        # selector symbol followed by `arg_types`' own, and is read through that offset. When the node's arguments
        # correspond otherwise, a sole hash argument may be the keyword hash, so the answer is nil (decline) and the
        # bare `Hash` stands; any other argument cannot be a keyword hash and is kept.
        def hash_new_positionals(arg_types, call_node)
          return arg_types[0...-1] if ArgumentNodes.keyword_hash_last?(call_node, arg_types)

          arguments = call_node.respond_to?(:arguments) ? call_node.arguments&.arguments : nil
          return arg_types if arguments.nil? || arguments.size == arg_types.size
          if arguments.size == arg_types.size + 1 && arguments.first.is_a?(Prism::SymbolNode)
            return arguments.last.is_a?(Prism::KeywordHashNode) ? arg_types[0...-1] : arg_types
          end

          arg_types.last.is_a?(Type::HashShape) ? nil : arg_types
        end

        # `Range.new(b, e)` / `Range.new(b, e, excl)` — folds to `Constant[Range]` when both
        # endpoints are `Constant[Integer]` or both are `Constant[String]`, and the optional third
        # argument is a `Constant[true/false]`. Nil endpoints (beginless / endless ranges) are not
        # folded because the useful instance methods (`to_a`, `first`, `last`) are not defined for
        # them; the RBS tier answers `Nominal[Range]` for those forms.
        def range_new_lift(class_name, arg_types)
          return nil unless class_name == "Range"
          return nil if arg_types.size < 2 || arg_types.size > 3

          b_type = arg_types[0]
          e_type = arg_types[1]

          return nil unless b_type.is_a?(Type::Constant) && e_type.is_a?(Type::Constant)

          b_val = b_type.value
          e_val = e_type.value

          # Only fold homogeneous Integer or String endpoint pairs.
          return nil unless b_val.instance_of?(e_val.class)
          return nil unless b_val.is_a?(Integer) || b_val.is_a?(String)

          excl = range_new_excl(arg_types[2])
          return nil if excl.nil?

          Type::Combinator.constant_of(Range.new(b_val, e_val, excl))
        rescue StandardError
          nil
        end

        # Resolves the optional `exclude_end` argument for `range_new_lift`. Returns `false` (no
        # arg), `true`/`false` (Constant[bool] arg), or `nil` to signal "decline" (wrong type /
        # wrong value class).
        def range_new_excl(excl_type)
          case excl_type
          when nil then false
          when Type::Constant
            excl_type.value if [true, false].include?(excl_type.value)
          end
        end

        # `Set.new` / `Set.new(tuple_of_constants)` — folds to `Constant[Set]` when zero arguments
        # are given or the single argument is a `Tuple` whose every element is a `Constant[T]`.
        # Mirrors `SetFolding#fold_new` but lives here so the `:new` path in
        # `try_dispatch` can reach it before the RBS tier answers `Nominal[Set]`.
        def set_new_lift(class_name, arg_types, context = nil)
          return nil unless class_name == "Set"

          SetFolding.fold_new(arg_types, context&.call_node, context&.block_type)
        end

        # `Regexp.new(pattern)` / `Regexp.new(pattern, opts)` — folds to `Constant[Regexp]` when
        # the pattern is a `Constant[String]`. Mirrors `RegexpFolding#fold_new` but lives here so
        # the `:new` path in `try_dispatch` can reach it.
        def regexp_new_lift(class_name, arg_types)
          return nil unless class_name == "Regexp"
          return nil if arg_types.empty? || arg_types.size > 2

          pattern_arg = arg_types.first
          return nil unless pattern_arg.is_a?(Type::Constant) && pattern_arg.value.is_a?(String)

          opts = if arg_types.size == 2
                   opt_type = arg_types[1]
                   return nil unless opt_type.is_a?(Type::Constant)

                   opt_type.value
                 else
                   0
                 end

          Type::Combinator.constant_of(Regexp.new(pattern_arg.value, opts))
        rescue StandardError
          nil
        end

        # `Date.new(y, m, d)` / `DateTime.new(y, m, d, h, min, s, off)` — folds to `Constant[Date]`
        # / `Constant[DateTime]` when every argument is a `Constant` carrying an Integer (or, for
        # the `DateTime` offset / `start` slots, a Rational or String). `Date.new` carries no
        # timezone, and `DateTime.new`'s offset defaults to UTC, so the literal is
        # machine-independent. `Date.today` / `Date.parse` are not constructors here — they are
        # non-deterministic / string-dependent and stay `Nominal[Date]`.
        DATE_NEW_CLASSES = %w[Date DateTime].freeze
        private_constant :DATE_NEW_CLASSES

        def date_new_lift(class_name, arg_types)
          return nil unless DATE_NEW_CLASSES.include?(class_name)
          return nil unless arg_types.size.between?(1, 8)
          return nil unless arg_types.all?(Type::Constant)

          values = arg_types.map(&:value)
          return nil unless values.all? { |v| v.is_a?(Integer) || v.is_a?(Rational) || v.is_a?(String) }

          klass = class_name == "Date" ? Date : DateTime
          Type::Combinator.constant_of(klass.new(*values))
        rescue StandardError
          nil
        end

        CONSTANT_METACLASSES = {
          Integer => "Integer", Float => "Float", String => "String",
          Symbol => "Symbol", Range => "Range",
          TrueClass => "TrueClass", FalseClass => "FalseClass",
          NilClass => "NilClass"
        }.freeze
        private_constant :CONSTANT_METACLASSES

        def constant_metaclass(value)
          CONSTANT_METACLASSES.each do |klass, name|
            return Type::Combinator.singleton_of(name) if value.is_a?(klass)
          end
          nil
        end
      end
    end
  end
end
