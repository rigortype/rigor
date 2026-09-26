# frozen_string_literal: true

require_relative "../../reflection"
require_relative "../../type"
require_relative "self_evidence"

module Rigor
  module Inference
    module LastLine
      # Issue #1415 (ADR-117 WD5) — whether an implicit-self or `self.` `gets` is the C reader, `Kernel`'s or a
      # reopened `IO`'s, under WD4's assumption that the readers a program relies on are the core ones. It is when
      # the file gives the reader a `self` ({SelfEvidence#context}) and that `self`'s ancestry holds no Ruby reader the
      # analyzer can see:
      #
      # - in the script body, a top-level method or a top-level `class << self`, whose `self` is `main`, while no file
      #   of the program records a mixin into `Object`, `Kernel` or `BasicObject` ({.root_mixin?}). A top-level method
      #   run with another `self`, a file loaded under `load(file, M)` and a DSL's `instance_eval(File.read(f))` are
      #   assumed away, as WD4 assumes a replacement the file does not show.
      # - in a class body and its methods, and in a module body and its singleton methods, while the class or module
      #   `self` names, and every ancestor the program records for it, resolves to a project class or to a class or
      #   module RBS knows ({.instance_side?}, {.class_side?}), none of them dirty ({SelfEvidence#dirty?}). A project
      #   ancestor adds its own ancestry; a superclass that is not a constant (`DelegateClass(File)`), or a class a
      #   constant write makes (`W = Class.new(CSV)`), records none, and declines, as does an ancestor name the
      #   program writes as a constant (`File = RubyReaderClass`). An ancestor RBS knows must place both readers in
      #   `Kernel`, `IO` or its kin (`CSV` places `readline` in `CSV`, and `OpenSSL::Buffering` both), or declare
      #   neither when it is a module, be no `Tempfile` or `CSV`, whose readers are Ruby though RBS places one or both
      #   in `IO` or `Kernel`, and have no RBS ancestor the program mixes a module into (`class IO; prepend M; end`
      #   reaches every `File`). A class object also declines on a mixin into `Module` or `Class`. A subclass the
      #   method runs on is assumed away, as a top-level method run with another `self` is.
      #
      # With dependency recording on (ADR-46), each project class the walk reads is an edge to its declarations, and
      # each root, RBS ancestor and constant name it asks about is a name edge, so a file that later mixes into one,
      # reopens one or writes one re-checks this one.
      module ImplicitSelf
        # `Kernel` answers for every object that inherits it, and for a reader RBS leaves out, which the checks on
        # the ancestry below answer for instead.
        OWNERS = (READER_OWNERS | Set["::Kernel"]).freeze
        RUBY_READER_CLASSES = (DELEGATING_CLASSES + %w[CSV]).freeze
        # The classes a mixin reaches every object from, and every class and module object from.
        INSTANCE_ROOTS = %w[Object Kernel BasicObject].freeze
        CLASS_ROOTS = %w[Module Class].freeze
        # The ancestry walk's node cap, as `Scope::ANCESTOR_WALK_LIMIT` caps the project walks.
        WALK_LIMIT = 100
        private_constant :OWNERS, :RUBY_READER_CLASSES, :INSTANCE_ROOTS, :CLASS_ROOTS, :WALK_LIMIT

        module_function

        def reader?(call_node, scope)
          evidence = scope.discovery.implicit_self_evidence
          context = evidence&.context(call_node)
          return false if context.nil? || root_mixin?(scope, INSTANCE_ROOTS)

          self_type = scope.self_type
          return self_type.nil? if context == SelfEvidence::MAIN

          case self_type
          when Type::Nominal then instance_side?(self_type.class_name, scope, evidence, {})
          when Type::Singleton
            !root_mixin?(scope, CLASS_ROOTS) && class_side?(self_type.class_name, scope, evidence, {})
          else false
          end
        end

        # A mixin into one of `roots` any file of the program records (`class Object; include M; end`), which reaches
        # every object's methods, or every class object's for `Module` and `Class`.
        def root_mixin?(scope, roots)
          roots.any? do |name|
            record_name(:class, name)
            !scope.includes_of(name).empty? || scope.discovered_extends.key?(name)
          end
        end

        # The instance side of `name`: its readers, and those of every ancestor the program records for it.
        def instance_side?(name, scope, evidence, seen)
          return true if seen.key?(name)
          return false if seen.size >= WALK_LIMIT || evidence.dirty?(name) || ruby_reader_class?(name, scope)

          seen[name] = true
          known = Reflection.rbs_class_known?(name, scope: scope)
          if project_class?(name, scope)
            return false if unnamed_superclass?(name, scope)

            ancestors = scope.includes_of(name) + Array(scope.superclass_of(name))
            return false unless ancestors.all? { |raw| instance_ancestor?(name, raw, scope, evidence, seen) }
            return true unless known
          end
          known && rbs_readers?(name, scope) && rbs_ancestry?(name, scope, evidence, seen, :instance)
        end

        # The class object `name`: the modules it and its superclasses extend, and their superclasses' class sides.
        def class_side?(name, scope, evidence, seen)
          return true if seen.key?(name)
          return false if seen.size >= WALK_LIMIT || evidence.dirty?(name)

          seen[name] = true
          known = Reflection.rbs_class_known?(name, scope: scope)
          if project_class?(name, scope)
            return false if unnamed_superclass?(name, scope)
            return false unless extensions?(name, scope, evidence)

            superclass = scope.superclass_of(name)
            return false unless superclass.nil? || class_ancestor?(name, superclass, scope, evidence, seen)
            return true unless known
          end
          known && rbs_class_readers?(name, scope) && rbs_ancestry?(name, scope, evidence, seen, :singleton)
        end

        def extensions?(name, scope, evidence)
          (scope.discovered_extends[name] || []).all? { |raw| instance_ancestor?(name, raw, scope, evidence, {}) }
        end

        def instance_ancestor?(owner, raw, scope, evidence, seen)
          ancestor = resolve(owner, raw, scope)
          !ancestor.nil? && instance_side?(ancestor, scope, evidence, seen)
        end

        def class_ancestor?(owner, raw, scope, evidence, seen)
          ancestor = resolve(owner, raw, scope)
          !ancestor.nil? && class_side?(ancestor, scope, evidence, seen)
        end

        # The ancestors RBS gives `name`, none dirty in the file, and none that the program mixes a module into, on
        # the instance side, or extends, on the class side, unless each module is clear itself: a class body that
        # reopens a core class (`class IO; prepend M; end`) reaches every class below it.
        def rbs_ancestry?(name, scope, evidence, seen, side)
          loader = scope.environment.rbs_loader
          return true if loader.nil?

          loader.ancestor_names_for(name).all? do |ancestor|
            next true if ancestor == name && project_class?(name, scope)

            record_name(:class, ancestor)
            next false if evidence.dirty?(ancestor)

            mixins = side == :instance ? scope.includes_of(ancestor) : scope.discovered_extends[ancestor] || []
            mixins.all? { |raw| instance_ancestor?(ancestor, raw, scope, evidence, side == :instance ? seen : {}) }
          end
        end

        def project_class?(name, scope)
          scope.discovered_classes.key?(name) || scope.known_user_class?(name)
        end

        # A superclass the discovery tables do not name: an expression other than a constant (`class W <
        # DelegateClass(File)`), which the superclass table keeps as its key with no name, and whatever a constant
        # write makes the class from (`W = Class.new(CSV)`, `W = DelegateClass(File)`), which only the in-source
        # constant table and, across files, the census of written constant names record.
        def unnamed_superclass?(name, scope)
          return true if written_constant?(name, scope)

          scope.discovered_superclasses.key?(name) && scope.superclass_of(name).nil?
        end

        # The ancestor `raw`, as `owner`'s declaration writes it, as the first candidate the program or RBS knows, or
        # nil when neither knows one or when a candidate before it is a constant the program writes, which shadows an
        # RBS name (`module Wrap; File = RubyReaderClass; class Src < File`) with whatever value it holds.
        def resolve(owner, raw, scope)
          scope.ancestor_name_candidates(owner, raw).each do |candidate|
            return nil if written_constant?(candidate, scope)
            return candidate if project_class?(candidate, scope) || Reflection.rbs_class_known?(candidate, scope: scope)
          end
          nil
        end

        # A name the file's in-source constant table holds, or one the project's census of written constant names
        # spells, exactly, as a `*::` wildcard of its last segment, or as a path relative to a namespace the census
        # does not record (`module P; Q::Qux = Class.new(CSV); end` spells `Q::Qux` for `P::Q::Qux`), which a
        # same-named constant elsewhere also matches, and only declines.
        def written_constant?(name, scope)
          record_name(:constant, name.split("::").last)
          return true if scope.in_source_constants.key?(name)

          scope.bound_constant_names(name).any? do |written|
            written == name || written.start_with?("*::") || name.end_with?("::#{written}")
          end
        end

        # Both readers in `Kernel`, `IO` or its kin; a module may declare neither, while a class without one is a
        # `BasicObject` lineage (`Delegator`), whose reader is a `method_missing` forwarder.
        def rbs_readers?(name, scope)
          READERS.all? do |reader|
            definition = Reflection.instance_method_definition(name, reader, scope: scope)
            definition.nil? ? scope.environment.rbs_module?(name) : OWNERS.include?(definition.defined_in.to_s)
          end
        end

        def rbs_class_readers?(name, scope)
          READERS.all? do |reader|
            definition = Reflection.singleton_method_definition(name, reader, scope: scope)
            !definition.nil? && OWNERS.include?(definition.defined_in.to_s)
          end
        end

        def ruby_reader_class?(name, scope)
          RUBY_READER_CLASSES.any? do |klass|
            DELEGATING_ORDERINGS.include?(scope.environment.class_ordering(name, klass))
          end
        end

        def record_name(kind, name)
          Analysis::DependencyRecorder.read_name(kind, name) if Analysis::DependencyRecorder.active?
        end

        private_class_method :root_mixin?, :instance_side?, :class_side?, :extensions?, :instance_ancestor?,
                             :class_ancestor?, :rbs_ancestry?, :project_class?, :unnamed_superclass?, :resolve,
                             :written_constant?, :rbs_readers?, :rbs_class_readers?, :ruby_reader_class?, :record_name
      end
    end
  end
end
