# frozen_string_literal: true

require "prism"

require_relative "project_patched_methods"
require_relative "../source/constant_path"

module Rigor
  module Inference
    module ProjectPatchedScanner
      # Issue #1708 — the `include` / `prepend` edges a `pre_eval:` file writes, so a module it mixes into an
      # ancestor (`Numeric.include(M)`) answers the receivers below that ancestor through
      # {ProjectPatchedMethods#lookup_through_ancestors}. Ruby 4.0.5: after `Numeric.include(NumExt)`, `1.inc_m` and
      # `1.5.inc_m` run.
      module Mixins
        # An `include` / `prepend` the walk met, with the lexical prefix {.resolve} resolves its module's written
        # name in.
        Pending = Data.define(:owner, :module_name, :kind, :prefix)

        CALLS = %i[include prepend].freeze
        private_constant :CALLS

        module_function

        # The {Pending} edges `node` writes, or none: `Numeric.include(M)` on a constant, or `include M` /
        # `self.include(M)` in a body. A top-level `include M` includes into `Object`, as Ruby's does. One in a
        # `class << self` body is an `extend`, which this does not read; a module argument that is not a constant is
        # skipped.
        def pending(node, qualified_prefix, in_singleton_class)
          return [] unless CALLS.include?(node.name) && node.arguments

          owner = owner(node.receiver, qualified_prefix, in_singleton_class)
          return [] if owner.nil?

          node.arguments.arguments.filter_map do |arg|
            name = Source::ConstantPath.qualified_name_or_nil(arg)
            next if name.nil?

            prefix = arg.is_a?(Prism::ConstantPathNode) && arg.parent.nil? ? [] : qualified_prefix
            Pending.new(owner: owner, module_name: name, kind: node.name, prefix: prefix)
          end
        end

        def owner(receiver, qualified_prefix, in_singleton_class)
          case receiver
          when nil, Prism::SelfNode
            return nil if in_singleton_class
            return "Object" if qualified_prefix.empty? && receiver.nil?

            qualified_prefix.join("::") unless qualified_prefix.empty?
          else
            Source::ConstantPath.qualified_name_or_nil(receiver)
          end
        end
        private_class_method :owner

        # Each {Pending} edge's module name, resolved as Ruby resolves the constant from where it is written:
        # `include NumExt` in `module Ext` names `Ext::NumExt` when a patch body opens that, else `NumExt`. Only the
        # names the `pre_eval:` files open or mix into are candidates; one they do not name stays as written.
        def resolve(pending, entries)
          known = entries.to_set(&:class_name).merge(pending.map(&:owner))
          pending.map do |item|
            candidates = item.prefix.size.downto(1).map do |depth|
              [*item.prefix.first(depth), item.module_name].join("::")
            end
            name = candidates.find { |candidate| known.include?(candidate) } || item.module_name
            ProjectPatchedMethods::Mixin.new(owner: item.owner, module_name: name, kind: item.kind)
          end
        end
      end
    end
  end
end
