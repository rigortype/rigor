# frozen_string_literal: true

require_relative "../reflection"
require_relative "../analysis/dependency_recorder"
require_relative "global_write_census"

module Rigor
  module Inference
    # Issue #1697 — the modules the project mixes into `Object`, and what they say about a method name.
    #
    # A top-level `include M` is `main.include`, which is `Object.include`, so M's instance methods exist on
    # every object: bare top-level calls (`main` is an `Object`) and calls on any receiver whose class
    # descends from `Object`. `ScopeIndexer` records that statement under its own owner key
    # ({TOPLEVEL_INCLUDE_KEY}), and an `include M` inside `class Object ... end` on `Object`. The RBS
    # environment knows nothing of either: `Object`'s RBS ancestry is core's, so a direct lookup on an
    # RBS-known receiver misses every one of M's methods. This module is the one place that asks the
    # project's `Object` edges instead, for the
    # `call.unresolved-toplevel` and `call.undefined-method` silences in `Analysis::CheckRules`, and for the one
    # shape `RbsDispatch` types through them ({sole_rbs_declaration}, issue #1715). What Ruby reaches first
    # depends on more than the chain shows (a block that rebinds `self`, an `extend` or a singleton `def` on
    # `main`, a definition of the name anywhere), so that typing is narrow by design.
    #
    # The edges are read through `Scope::ResolutionChain`, the two owners' instance chains, whose search
    # files the ADR-46 class edge of every project entry it passes, the declaring files among them (a file
    # that wrote a top-level `include` is one), so a consumer re-checks when the include that answered for
    # it is edited away. A project that never reopens `Object` and writes no top-level `include` returns
    # before reading anything. The question is a union over the chain, not "which definer does Ruby call":
    # any entry that may define the name answers, so the chain's `settle` verdict is not asked.
    module ObjectMixins
      OWNER = "Object"
      # The owner key `ScopeIndexer` files a top-level `include` under, beside `Object`'s own key, so that
      # no ancestry walk that types a call reaches it (see `ScopeIndexer#toplevel_include_owner`).
      TOPLEVEL_INCLUDE_KEY = "<toplevel-include>"

      module_function

      # How the project's `Object` mixins answer `method_name`, nearest edge first:
      #
      # - `[:rbs, module_name, definition]` — an RBS-declared module declares it; `definition` is its
      #   `RBS::Definition::Method`. `:private_rbs` is the same for a private declaration, which a bare call
      #   reaches and a call with a receiver does not.
      # - `[:source, module_name]` — a project module (or `Object` itself) defines it.
      # - `[:singleton_function, module_name]` — an RBS-declared module declares it only as a singleton method.
      #   Core declares `Math`'s functions that way (`def self.sqrt`) although they are `module_function`s,
      #   whose private instance copies a bare call reaches after `include Math`. RBS cannot tell such a
      #   function from a plain `def self.`, so the answer silences a bare call only.
      # - `[:opaque, module_name]` — a module neither RBS nor the project declares. Its surface cannot be
      #   enumerated, so it may define the name.
      # - `[:truncated, "Object"]` — the chain was cut at its budget with no answer before the cut: a definer
      #   may sit past it, which is uncertainty, not absence.
      # - `nil` — no edge, or every edge names a module known not to declare it.
      #
      # `skip:` names the kinds a caller cannot use; an entry of one of them is passed over and the search
      # goes on to the next, so the answer is a union over the chain for those callers rather than the
      # nearest entry only.
      def answer(scope, method_name, skip: NO_SKIP)
        return nil if scope.nil?

        # ADR-46 — the answer depends on whether a top-level `include` exists anywhere, so a consumer checked
        # while none did must re-check when one appears. The key appears as a declared "class" of the file that
        # writes it (`discovered_class_sources`), which is what this name-keyed existence edge listens for.
        if Analysis::DependencyRecorder.active?
          Analysis::DependencyRecorder.read_last_segment(:class, TOPLEVEL_INCLUDE_KEY)
        end
        EDGE_OWNERS.each do |owner|
          next unless scope.known_user_class?(owner)

          found = answer_on_chain(scope, owner, method_name, skip)
          return found if found
        end
        nil
      end

      # Where `Object`'s project edges are recorded: a top-level `include` under the indexer's own key, and
      # `Object` itself for `include M` in `class Object` (and `Object`'s own definitions).
      EDGE_OWNERS = [TOPLEVEL_INCLUDE_KEY, OWNER].freeze
      private_constant :EDGE_OWNERS

      def answer_on_chain(scope, owner, method_name, skip)
        chain = Scope::ResolutionChain.for(scope, owner, :instance, :methods)
        found = chain.search(scope, side: :instance) do |entry|
          entry_answer = answer_for_entry(scope, entry, method_name)
          entry_answer unless entry_answer.nil? || skip.include?(entry_answer.first)
        end
        return found if found

        chain.truncated? ? [:truncated, owner] : nil
      end
      private_class_method :answer_on_chain

      NO_SKIP = [].freeze
      # An explicit receiver reaches neither a private method (a `module_function`'s instance copy among
      # them) nor, on #746's
      # reading of an ancestor's unknown include (the receiver's own includes only), a module whose surface
      # is unknown: one top-level `include` of an undeclared module would otherwise silence
      # `call.undefined-method` on every receiver in the project.
      EXPLICIT_RECEIVER_SKIP = %i[private_rbs singleton_function opaque].freeze
      private_constant :NO_SKIP, :EXPLICIT_RECEIVER_SKIP

      # Issue #1715 — the RBS declaration a bare call in a top-level statement position reaches through a top-level
      # `include`, or nil when anything may answer the name instead. The caller has already placed the call
      # ({ToplevelStatementCalls}); this answers for the name, and only when every one of these holds:
      #
      # - the program defines the name nowhere, in any spelling, on any receiver, and holds no definition whose name
      #   no literal spells nor a string eval ({GlobalWriteCensus.defines_or_may_define?}, the `pre_eval:` files'
      #   census included). This covers a top-level `def`, `def self.x` / `class << self` / `define_method` /
      #   `alias` on `main`, `Object.define_method`, an `extend`ed source module's method, and a `def` of the name
      #   on any class, which an object may reach in ways no table records;
      # - every module mixed in at the top level by `include`, `extend` or `prepend` (the census's main mixins) is
      #   a top-level `include` the indexer recorded: an `extend` is nearer than any `include`, and one written in a
      #   block may not reach `main` at all;
      # - nothing on `Object`'s own chain (`class Object; include M; end`) answers the name;
      # - exactly one entry of the top-level include chain answers, an RBS module declaring the name as a public
      #   instance method, and the chain was not cut at its budget. Cross-file include order is unknown, so a second
      #   answer of any kind (an undeclared module included) is ambiguous.
      #
      # The answer depends on the whole program's census, so it files the name edges an incremental recheck matches
      # against a census change (`defines:<name>` and `defines:*`, {CENSUS_ANY_KEY}), beside the include chain's
      # edges.
      def sole_rbs_declaration(scope, method_name)
        return nil if scope.nil?

        record_census_edges(method_name)
        if Analysis::DependencyRecorder.active?
          Analysis::DependencyRecorder.read_last_segment(:class, TOPLEVEL_INCLUDE_KEY)
        end
        return nil unless scope.known_user_class?(TOPLEVEL_INCLUDE_KEY)
        return nil if census_declines?(scope, method_name.to_sym)
        return nil if scope.known_user_class?(OWNER) && answer_on_chain(scope, OWNER, method_name, NO_SKIP)

        sole_chain_declaration(scope, method_name)
      end

      # The census key {sole_rbs_declaration} files for a census entry that is not a named definition: a marker
      # (a computed name, a string eval) or a main mixin.
      CENSUS_ANY_KEY = "*"

      def record_census_edges(method_name)
        return unless Analysis::DependencyRecorder.active?

        Analysis::DependencyRecorder.read_name(:defines, method_name.to_s)
        Analysis::DependencyRecorder.read_name(:defines, CENSUS_ANY_KEY)
      end
      private_class_method :record_census_edges

      def census_declines?(scope, name)
        census = scope.discovered_global_write_census
        pre_eval = scope.environment&.project_patched_methods&.write_census
        return true if GlobalWriteCensus.defines_or_may_define?(census, name)
        return true if pre_eval && GlobalWriteCensus.defines_or_may_define?(pre_eval, name)

        included = Array(scope.discovered_includes[TOPLEVEL_INCLUDE_KEY]).map { |raw| raw.to_s.delete_prefix("::") }
        mixins = GlobalWriteCensus.main_mixins(census)
        mixins += GlobalWriteCensus.main_mixins(pre_eval) if pre_eval
        mixins.any? { |mixin| !included.include?(mixin) }
      end
      private_class_method :census_declines?

      def sole_chain_declaration(scope, method_name)
        chain = Scope::ResolutionChain.for(scope, TOPLEVEL_INCLUDE_KEY, :instance, :methods)
        answers = []
        chain.search(scope, side: :instance) do |entry|
          entry_answer = answer_for_entry(scope, entry, method_name)
          answers << entry_answer if entry_answer
          answers.size > 1 # a second answer makes it ambiguous: stop
        end
        return nil if chain.truncated? || answers.size != 1 || answers.first.first != :rbs

        answers.first[2]
      end
      private_class_method :sole_chain_declaration

      # Whether some `Object` mixin may define `method_name`: the question the silences ask. A bare
      # top-level call (`receiver: :implicit`, `call.unresolved-toplevel`) counts every answer, an unknown
      # module's included: such an include is the likeliest source of a bare name, and silencing a typo
      # there is the cheaper error. A call with a receiver (`receiver: :explicit`, `call.undefined-method`)
      # counts only a declared, public definition.
      def may_define?(scope, method_name, receiver:)
        skip = receiver == :explicit ? EXPLICIT_RECEIVER_SKIP : NO_SKIP
        !answer(scope, method_name, skip: skip).nil?
      end

      # Whether a receiver of `class_name` reaches `Object`'s mixins at all: `Object` itself, or an RBS
      # class the environment orders below it. A `BasicObject` subclass does not; a class the environment
      # cannot order is not claimed.
      def reaches_object?(scope, class_name)
        name = class_name.to_s.delete_prefix("::")
        return true if name == OWNER

        environment = scope&.environment
        !environment.nil? && environment.class_ordering(name, OWNER) == :subclass
      end

      # A project entry (`Object` itself, or a project module mixed into it) answers when it defines the name;
      # an external one when RBS declares the name on one of the names its spelling can denote (as an instance
      # method, or as a module's singleton function), and is opaque when none of those names is declared at
      # all.
      def answer_for_entry(scope, entry, method_name)
        unless entry.external?
          return source_defines?(scope, entry.name, method_name) ? [:source, entry.name] : nil
        end

        entry.candidates.each do |candidate|
          definition = Rigor::Reflection.instance_method_definition(candidate, method_name, scope: scope)
          return [private_definition?(definition) ? :private_rbs : :rbs, candidate, definition] if definition
          return [:singleton_function, candidate] if singleton_function?(scope, candidate, method_name)
        end
        return nil if entry.candidates.any? { |candidate| declared?(scope, candidate) }

        [:opaque, entry.raw.to_s]
      end
      private_class_method :answer_for_entry

      def private_definition?(definition)
        definition.respond_to?(:accessibility) && definition.accessibility == :private
      end
      private_class_method :private_definition?

      def singleton_function?(scope, name, method_name)
        environment = scope.environment
        return false if environment.nil? || !environment.rbs_module?(name)

        definition = Rigor::Reflection.singleton_method_definition(name, method_name, scope: scope)
        # Declared on the module itself: its singleton class also answers every `Module` method
        # (`include`, `name`), which no `include` of it brings to the top level.
        !definition.nil? && definition.defined_in.to_s.delete_prefix("::") == name
      end
      private_class_method :singleton_function?

      # Asked of both tables a project method lands in, as `RbsDispatch#source_declares_through_ancestors?`
      # does: `discovered_methods` withholds a plain `def` written in another file, which is exactly where a
      # top-level `include` usually finds its module. The chain already expands each module's own ancestry, so
      # one entry's own tables are asked.
      def source_defines?(scope, name, method_name)
        scope.discovered_method?(name, method_name, :instance) || !scope.user_def_for(name, method_name).nil?
      end
      private_class_method :source_defines?

      # The same "is this mixin's surface enumerable" reading `Analysis::CheckRules#known_mixin?` gives a
      # class's own includes (#746): a project class or module, or an RBS declaration Rigor did not
      # synthesize to keep a broken signature buildable.
      def declared?(scope, name)
        return true if scope.discovered_classes.key?(name)
        return false unless Rigor::Reflection.rbs_class_known?(name, scope: scope)

        loader = scope.environment&.rbs_loader
        return true if loader.nil? || !loader.respond_to?(:synthesized_type_names)

        !loader.synthesized_type_names.include?(name)
      end
      private_class_method :declared?
    end
  end
end
