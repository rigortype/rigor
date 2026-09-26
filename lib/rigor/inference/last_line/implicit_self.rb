# frozen_string_literal: true

require_relative "../../reflection"
require_relative "../../type"
require_relative "self_evidence"

module Rigor
  module Inference
    module LastLine
      # Issue #1415 (ADR-117 WD5) — whether an implicit-self or `self.` `gets` / `readline` is the C reader, `Kernel`'s
      # or a reopened `IO`'s, under WD4's assumption that the readers a program relies on are the core ones. It is
      # when the file gives the reader a `self` ({SelfEvidence#context}) and that `self`'s ancestry holds no Ruby
      # reader the analyzer can see:
      #
      # - in the script body, a top-level method or a top-level `class << self`, whose `self` is `main`, while no file
      #   of the program records a mixin into `Object`, `Kernel` or `BasicObject` ({.root_mixin?}). A top-level method
      #   run with another `self`, a file loaded under `load(file, M)` and a DSL's `instance_eval(File.read(f))` are
      #   assumed away, as WD4 assumes a replacement the file does not show.
      # - in a class body and its methods, and in a module body and its singleton methods, while the class or module
      #   `self` names, and every ancestor the program records for it, resolves to a project class or to a class or
      #   module RBS knows ({.instance_side?}, {.class_side?}). A project ancestor adds its own ancestry; a superclass
      #   that is not a constant (`DelegateClass(File)`), or a class a constant write makes (`W = Class.new(CSV)`),
      #   records none, and declines. An ancestor RBS knows must place both readers in `Kernel`, `IO` or its kin
      #   (`CSV` places `readline` in `CSV`, and `OpenSSL::Buffering` both), or declare neither when it is a module,
      #   and be no `Tempfile` or `CSV`, whose readers are Ruby though RBS places one or both in `IO` or `Kernel`. A
      #   subclass the method runs on is assumed away, as a top-level method run with another `self` is.
      module ImplicitSelf
        # `Kernel` answers for every object that inherits it, and for a reader RBS leaves out, which the checks on
        # the ancestry below answer for instead.
        OWNERS = (READER_OWNERS | Set["::Kernel"]).freeze
        RUBY_READER_CLASSES = (DELEGATING_CLASSES + %w[CSV]).freeze
        ROOTS = %w[Object Kernel BasicObject].freeze
        # The ancestry walk's node cap, as `Scope::ANCESTOR_WALK_LIMIT` caps the project walks.
        WALK_LIMIT = 100
        private_constant :OWNERS, :RUBY_READER_CLASSES, :ROOTS, :WALK_LIMIT

        module_function

        def reader?(call_node, scope)
          context = scope.discovery.implicit_self_evidence&.context(call_node)
          return false if context.nil? || root_mixin?(scope)

          self_type = scope.self_type
          return self_type.nil? if context == SelfEvidence::MAIN

          case self_type
          when Type::Nominal then instance_side?(self_type.class_name, scope, {})
          when Type::Singleton then class_side?(self_type.class_name, scope, {})
          else false
          end
        end

        # A mixin into `Object`, `Kernel` or `BasicObject` any file of the program records (`class Object; include
        # M; end`), which reaches every object's methods.
        def root_mixin?(scope)
          [scope.discovered_includes, scope.discovered_prepends, scope.discovered_extends].any? do |table|
            ROOTS.any? { |name| table.key?(name) }
          end
        end

        # The instance side of `name`: its readers, and those of every ancestor the program records for it.
        def instance_side?(name, scope, seen)
          return true if seen.key?(name)
          return false if seen.size >= WALK_LIMIT || ruby_reader_class?(name, scope)

          seen[name] = true
          known = Reflection.rbs_class_known?(name, scope: scope)
          return known && rbs_readers?(name, scope) unless project_class?(name, scope)
          return false if unnamed_superclass?(name, scope)

          ancestors = scope.includes_of(name) + Array(scope.superclass_of(name))
          return false unless ancestors.all? { |raw| instance_ancestor?(name, raw, scope, seen) }

          !known || rbs_readers?(name, scope)
        end

        # The class object `name`: the modules it and its superclasses extend, and their superclasses' class sides.
        def class_side?(name, scope, seen)
          return true if seen.key?(name)
          return false if seen.size >= WALK_LIMIT

          seen[name] = true
          known = Reflection.rbs_class_known?(name, scope: scope)
          return known && rbs_class_readers?(name, scope) unless project_class?(name, scope)
          return false if unnamed_superclass?(name, scope)

          extends = scope.discovered_extends[name] || []
          return false unless extends.all? { |raw| instance_ancestor?(name, raw, scope, {}) }

          superclass = scope.superclass_of(name)
          return false unless superclass.nil? || class_ancestor?(name, superclass, scope, seen)

          !known || rbs_class_readers?(name, scope)
        end

        def instance_ancestor?(owner, raw, scope, seen)
          ancestor = resolve(owner, raw, scope)
          !ancestor.nil? && instance_side?(ancestor, scope, seen)
        end

        def class_ancestor?(owner, raw, scope, seen)
          ancestor = resolve(owner, raw, scope)
          !ancestor.nil? && class_side?(ancestor, scope, seen)
        end

        def project_class?(name, scope)
          scope.discovered_classes.key?(name) || scope.known_user_class?(name)
        end

        # A superclass the discovery tables do not name: an expression other than a constant (`class W <
        # DelegateClass(File)`), which the superclass table keeps as its key with no name, and whatever a constant
        # write makes the class from (`W = Class.new(CSV)`, `W = DelegateClass(File)`), which only the in-source
        # constant table and, across files, the census of written constant names record (any write of the name's
        # last segment counts).
        def unnamed_superclass?(name, scope)
          return true if scope.in_source_constants.key?(name) || !scope.bound_constant_names(name).empty?

          scope.discovered_superclasses.key?(name) && scope.superclass_of(name).nil?
        end

        # The ancestor `raw`, as `owner`'s declaration writes it, as the first candidate the program or RBS knows, or
        # nil when neither knows one.
        def resolve(owner, raw, scope)
          scope.ancestor_name_candidates(owner, raw).find do |candidate|
            project_class?(candidate, scope) || Reflection.rbs_class_known?(candidate, scope: scope)
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

        private_class_method :root_mixin?, :instance_side?, :class_side?, :project_class?, :unnamed_superclass?,
                             :instance_ancestor?, :class_ancestor?, :resolve, :rbs_readers?, :rbs_class_readers?,
                             :ruby_reader_class?
      end
    end
  end
end
