# frozen_string_literal: true

require_relative "global_write_census"

module Rigor
  module Inference
    # ADR-17 § "Inference contract" — project-wide patched-method registry populated by the pre-eval
    # pre-pass (slice 2) from the user's `.rigor.yml` `pre_eval:` list.
    #
    # Each entry records one `def`, `alias` or `alias_method` declaration the pre-pass observed inside a class /
    # module body. The dispatcher's `try_project_patched_method` tier consults this registry between the plugin
    # tier and the dependency-source tier so project-side `lib/core_ext/string_extensions.rb` patches are visible
    # to cross-file dispatch.
    #
    # The dispatcher answers `Dynamic[T]` (with a heuristic static facet) when `Entry#return_type` is
    # non-nil, or `Dynamic[Top]` when the heuristic declined (`nil`). See {Entry} for the per-field
    # contract.
    class ProjectPatchedMethods
      # Frozen value-object recording one `def` observed by the pre-pass. `class_name` is the qualified
      # prefix (`"String"`, `"Foo::Bar"`); `method_name` is the declared name; `kind` is `:instance` or
      # `:singleton`; `source_path` / `source_line` carry attribution for diagnostics; `return_type` is
      # the {Analysis::DependencySourceInference::ReturnTypeHeuristic}-extracted static facet (a
      # `Rigor::Type::*`) or `nil` when the heuristic declined. The dispatcher wraps a non-nil
      # `return_type` in `Dynamic[T]`; a `nil` `return_type` falls back to `Dynamic[top]`.
      #
      # Issue #1702 — an `alias new old` / `alias_method :new, :old` in a patch is recorded too. When a `def` or
      # alias earlier in the `pre_eval:` files binds `old`, the alias's entry copies that entry's `return_type` (and
      # its `alias_of`); otherwise `alias_of` names `old`, a method the class had before the patch, and the
      # dispatcher answers the alias with what that method answers. `alias_of` is nil for a `def`.
      #
      # Issue #1708 — `visibility` is `:public`, `:private` or `:protected`, as the patch file leaves the method: a
      # `private def x`, a `def` after a bare `private` in the same body, a later `private :x`, and the instance copy
      # a `module_function` makes are `:private` ({#callable?} reads it). An alias takes its old name's visibility,
      # as Ruby's does; one whose old name no patch binds is `:public`.
      #
      # `farther` is set only on an entry {#lookup_through_ancestors} returns: the other definers of the name farther
      # on the walk (entries, or {SOURCE_DEFINER} for a project-source `def`), which {#callable?} reads before it
      # refuses the call.
      Entry = Data.define(:class_name, :method_name, :kind, :source_path, :source_line, :return_type, :alias_of,
                          :visibility, :farther) do
        def initialize(class_name:, method_name:, kind:, source_path:, source_line:, return_type: nil, alias_of: nil,
                       visibility: :public, farther: nil)
          super
        end
      end

      # Issue #1708 — one `include` or `prepend` a `pre_eval:` file writes (`Numeric.include(M)`, or `include M` in
      # `class Numeric`): `owner` gains `module_name` as an ancestor, `kind` `:include` or `:prepend`. Names are as
      # written, with no lexical resolution, as a patch's class name is.
      Mixin = Data.define(:owner, :module_name, :kind)

      attr_reader :by_key, :write_census, :mixins, :overrides

      # Each owner's prepended and included modules, the most recent first.
      def self.mixins_by_owner(mixins)
        table = mixins.each_with_object({}) do |mixin, acc|
          edges = (acc[mixin.owner] ||= { prepend: [], include: [] })
          edges[mixin.kind].unshift(mixin.module_name)
        end
        table.each_value { |edges| edges.each_value(&:freeze) }.freeze
      end

      # @param entries — flat list of declarations observed during the pre-pass.
      #   Last-write-wins on `(class_name, method_name, kind)` duplicates, as at runtime (ADR-17); the
      #   `pre-eval.duplicate-declaration` diagnostic emission stays decoupled from registry behaviour.
      # @param write_census — issue #1367: the `pre_eval:` files' {GlobalWriteCensus}, which the `global.*` write
      #   rules join with the project's, since a patch file is loaded ahead of the code it patches.
      # @param mixins — issue #1708: the {Mixin} edges the `pre_eval:` files write, in the order they run.
      # @param overrides — issue #1708: `[class_name, method_name, kind] => visibility` for a named visibility call
      #   (`public :kp` in `class Integer`) on a method the class inherits rather than binds, which Ruby copies onto
      #   the class with that visibility.
      def initialize(entries: [], write_census: GlobalWriteCensus::EMPTY, mixins: [], overrides: {})
        @by_key = entries.each_with_object({}) do |entry, acc|
          key = [entry.class_name, entry.method_name, entry.kind]
          acc[key] = entry
        end.freeze
        @write_census = write_census.frozen? ? write_census : write_census.dup.freeze
        @mixins = mixins.dup.freeze
        @mixins_of = ProjectPatchedMethods.mixins_by_owner(@mixins)
        @overrides = overrides.dup.freeze
        freeze
      end

      # @return the recorded entry for the given `(class_name, method_name, kind)` triple,
      #   or `nil` when no pre-eval file declared it.
      def lookup(class_name:, method_name:, kind:)
        @by_key[[class_name, method_name, kind]]
      end

      # Issue #1708 — the entry a `kind` receiver of `class_name` reaches through its ancestors, searched in Ruby's
      # order: a patch on `Object`, `Kernel`, `Numeric`, `Comparable` or `Enumerable` answers an `Integer`, `Array`
      # or `String` receiver, and a patch on a nearer ancestor wins over one on a farther. A class object's chain
      # is its singleton classes, then `Class`, `Module`, `Object`, `Kernel` and `BasicObject`, so `def zz` in
      # `class Object` answers `Integer.zz` too. The ancestors are the class's RBS ones; a class RBS does not
      # declare is searched as itself only, as {#lookup} searches it.
      #
      # It answers only which patch the chain holds. A method a nearer ancestor's RBS declares wins over the patch
      # in Ruby, so the callers ask once that RBS has come back without the method. A method the project's own
      # source defines on the way wins too: `source_defines` is called with each `owner, side` BEFORE that owner's
      # patch is read, and when it answers true the walk stops with no entry, leaving the call to what types that
      # method. That includes an owner holding both a patch and a source `def` (a `lib/` reopen loaded after the
      # patch, or a module the project prepends to it), unlike {#lookup}, which answers the patch.
      #
      # A module the `pre_eval:` files include into or prepend to an owner on the way ({Mixin}) is searched where Ruby
      # puts it: prepends ahead of the owner, includes after it, the most recent first, each with its own mixins. A
      # named visibility call on an owner the walk passes before the body (`public :kp` in `class Integer`, an
      # override) gives the entry it returns that visibility, and that owner for {#callable?}'s protected check.
      # @return the entry, or `nil` when no ancestor's patch declares the method ahead of a source `def`.
      def lookup_through_ancestors(class_name:, method_name:, kind:, rbs_loader:, source_defines: nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        return nil if empty?

        override = nil
        found = nil
        farther = []
        ancestor_keys(class_name.to_s, kind, rbs_loader).each do |owner, side|
          if source_defines&.call(owner, side)
            return nil if found.nil?

            farther << SOURCE_DEFINER
            break
          end

          entry = @by_key[[owner, method_name, side]]
          if found
            farther << entry if entry
          elsif entry
            found = override ? entry.with(class_name: override.first, visibility: override.last) : entry
          elsif (visibility = @overrides[[owner, method_name, side]])
            override ||= [owner, visibility]
          end
        end
        farther.empty? || found.nil? ? found : found.with(farther: farther.freeze)
      end

      # A project-source `def` of the name farther on the walk than the entry it returns, in {Entry#farther}.
      SOURCE_DEFINER = Object.new.freeze

      # Issue #1708 — whether Ruby lets a call reach `entry`. A public method answers any call; a private one only a
      # call with no receiver or with `self` as it (`explicit` is false for those); a protected one also a call from
      # a method whose `self` is an instance of the entry's owner. `self_type` is the caller's `self` (`nil` at the
      # top level, where it is `main`, an Object); a `self` this cannot name (the default) may be one, so a
      # protected entry answers it.
      #
      # It never refuses a call some other definer of the name may answer: the walk's order is an approximation
      # (a module two owners mix in is spliced at the nearer one, where Ruby keeps the first include and skips the
      # second), so when {Entry#farther} holds a definer the call may reach (a project-source `def`, or an entry this
      # would let it reach), it answers nil: decline, neither refused nor typed from `entry`.
      # @return true (the call reaches `entry`), false (Ruby refuses it), or nil (declined).
      def callable?(entry, explicit:, self_type: :unknown, rbs_loader: nil)
        return true unless explicit

        allowed =
          case entry.visibility
          when :private, :module_function then false
          when :protected then self_kind_of?(self_type, entry.class_name, rbs_loader)
          else true
          end
        return true if allowed

        reachable = (entry.farther || []).any? do |other|
          other.equal?(SOURCE_DEFINER) || callable?(other, explicit: true, self_type: self_type, rbs_loader: rbs_loader)
        end
        reachable ? nil : false # rubocop:disable Style/ReturnNilInPredicateMethodDefinition
      end

      def empty?
        @by_key.empty?
      end

      EMPTY = new.freeze

      private

      # Whether `self_type` may be an instance of `owner`: false only when the ancestors of a class RBS knows,
      # with the patches' mixins, do not hold it.
      def self_kind_of?(self_type, owner, rbs_loader)
        name, kind =
          if self_type.nil? then ["Object", :instance]
          elsif self_type.respond_to?(:class_name) && self_type.class_name
            [self_type.class_name.to_s, self_type.is_a?(Type::Singleton) ? :singleton : :instance]
          end
        return true if name.nil? || rbs_loader.nil?

        keys = ancestor_keys(name, kind, rbs_loader)
        keys == [[name, kind]] || keys.include?([owner, :instance])
      end

      def ancestor_keys(class_name, kind, rbs_loader)
        pairs =
          if kind == :singleton
            sides = rbs_loader ? rbs_loader.singleton_ancestors_for(class_name) : []
            sides.empty? ? [[class_name, :singleton]] : sides.map { |side, owner| [owner, side] }
          else
            names = rbs_loader ? rbs_loader.ancestor_names_for(class_name) : []
            (names.empty? ? [class_name] : names).map { |owner| [owner, :instance] }
          end
        @mixins_of.empty? ? pairs : with_mixins(pairs)
      end

      # The RBS ancestor pairs with each instance-side owner's `pre_eval:` mixins spliced in. A module already on
      # the chain is not added again, as Ruby skips a module the ancestors already hold.
      def with_mixins(pairs)
        chain = pairs.filter_map { |owner, side| owner if side == :instance }.to_set
        seen = Set.new
        pairs.flat_map do |owner, side|
          side == :instance ? expand_mixins(owner, chain, seen).map { |name| [name, :instance] } : [[owner, side]]
        end
      end

      # `owner` with the modules the patches prepend to it ahead and the ones they include after, each expanded the
      # same way: the order Ruby's `ancestors` lists them in. An include of a module the RBS chain already holds
      # changes nothing, as Ruby skips it (`Integer.include(Comparable)`); a prepend of one is spliced ahead all the
      # same, as Ruby adds it again (`Integer.prepend(Comparable)`). `seen` holds the modules already spliced, so a
      # module is spliced once, at the nearest owner that mixes it in, and an include cycle ends. Ruby skips
      # `Integer.include(A)` run after `Numeric.include(A)`, leaving A after Numeric; the registry, which does not read
      # the order the two edges ran in, splices A after Integer either way.
      def expand_mixins(owner, chain, seen)
        edges = @mixins_of[owner]
        return [owner] if edges.nil?

        ahead = edges[:prepend].flat_map { |name| seen.add?(name) ? expand_mixins(name, chain, seen) : [] }
        after = edges[:include].flat_map do |name|
          !chain.include?(name) && seen.add?(name) ? expand_mixins(name, chain, seen) : []
        end
        ahead + [owner] + after
      end
    end
  end
end
