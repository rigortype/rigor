# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    module SyntheticMethodScanner
      # The instance-method names a project class answers ahead of a module a trait registry includes into it
      # (PR #2286 review S1). Ruby looks a method up on the class itself before any module it includes, and a
      # module the class itself includes or prepends sits ahead of one `devise` included earlier — so where
      # the project names a member, the Tier B entry for it would answer the call from the wrong rung:
      #
      #   class User < ApplicationRecord
      #     devise :confirmable
      #     include PasswordPolicy   # defines password_required?
      #     def confirmed? = :yes
      #   end
      #
      # `User.new.confirmed?` is `:yes` and `password_required?` is the policy's, not `bool` from the Devise
      # module's RBS. {SyntheticMethodScanner} therefore drops a trait entry whose name this index reports.
      #
      # A name counts as the class's when any reopening of the class body (in any project file) writes `def`,
      # `alias` / `alias_method`, `attr_*`, `define_method` or `delegate` for it, or when a project module the
      # class includes or prepends (followed through that module's own `include` / `prepend`) does. The MRO
      # order of an `include` relative to the `devise` call is NOT consulted: a module included before the
      # call sits behind the Devise module at runtime, but the name is declined anyway. Declining is the
      # conservative direction — the call then reaches the tiers below the synthetic one (the discovered
      # method, the project mixin), which answer it as they did before Tier B was reachable. A mixin constant
      # is matched to a project module by name or by `::`-suffix, again widening only what is declined.
      class ProjectMembers
        # The calls that name members through their literal arguments, and the suffixes each name takes.
        SUFFIXES_BY_CALL = Ractor.make_shareable(
          {
            attr_reader: [""], attr: [""], attr_writer: ["="], attr_accessor: ["", "="], delegate: [""]
          }
        )
        NAME_ARG_CALLS = %i[define_method alias_method].freeze
        MIXIN_CALLS = %i[include prepend].freeze

        Entry = Struct.new(:names, :mixins)
        private_constant :Entry

        def initialize(asts)
          @classes = Hash.new { |hash, key| hash[key] = Entry.new(Set.new, []) }
          @modules = Hash.new { |hash, key| hash[key] = Entry.new(Set.new, []) }
          asts.each_value { |ast| walk_namespaces(ast, []) unless ast.nil? }
          @declared = {}
        end

        # True when `class_name`'s own body, or a project module it includes or prepends, names `method_name`.
        def declares?(class_name, method_name)
          (@declared[class_name] ||= declared_names(class_name)).include?(method_name.to_sym)
        end

        private

        def declared_names(class_name)
          entry = @classes.fetch(class_name, nil)
          return Set.new.freeze if entry.nil?

          names = entry.names.dup
          visited = Set.new
          queue = entry.mixins.dup
          until queue.empty?
            module_keys_for(queue.shift).each do |key|
              next unless visited.add?(key)

              names.merge(@modules[key].names)
              queue.concat(@modules[key].mixins)
            end
          end
          names.freeze
        end

        def module_keys_for(name)
          @modules.keys.select { |key| key == name || key.end_with?("::#{name}") }
        end

        def walk_namespaces(node, scope_stack)
          case node
          when Prism::ClassNode, Prism::ModuleNode
            name = SyntheticMethodScanner.class_name_from(node, scope_stack)
            if name
              table = node.is_a?(Prism::ClassNode) ? @classes : @modules
              collect_members(node.body, table[name])
            end
            inner = scope_stack + [node]
            node.body&.rigor_each_child { |child| walk_namespaces(child, inner) }
          else
            node.rigor_each_child { |child| walk_namespaces(child, scope_stack) }
          end
        end

        # Every member-naming form under the namespace body, at any depth short of a nested namespace (a
        # `private def`, a `def` under a conditional and an `included do ... def` all count). A nested `class`,
        # `module` or `class << self` is another namespace's body.
        def collect_members(node, entry)
          return if node.nil?

          case node
          when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode then return
          when Prism::DefNode then entry.names << node.name if node.receiver.nil?
          when Prism::AliasMethodNode then add_symbol(entry, node.new_name)
          when Prism::CallNode then collect_call(node, entry)
          end
          node.rigor_each_child { |child| collect_members(child, entry) }
        end

        def collect_call(call, entry)
          return unless call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode)

          args = call.arguments&.arguments || []
          if MIXIN_CALLS.include?(call.name)
            entry.mixins.concat(args.filter_map { |arg| SyntheticMethodScanner.const_name_string(arg) })
          elsif NAME_ARG_CALLS.include?(call.name)
            add_symbol(entry, args.first)
          elsif (suffixes = SUFFIXES_BY_CALL[call.name])
            args.each { |arg| suffixes.each { |suffix| add_symbol(entry, arg, suffix: suffix) } }
          end
        end

        def add_symbol(entry, node, suffix: "")
          value = Source::Literals.symbol_or_string_name(node)
          entry.names << :"#{value}#{suffix}" unless value.nil?
        end
      end
    end
  end
end
