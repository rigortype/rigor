# frozen_string_literal: true

require "rigor/source/node_children"

require "prism"

module Rigor
  module Plugin
    class Actionpack < Rigor::Plugin::Base
      # The syntactic controller walk two parent-side indexes share: {ViewAssigns}, which reads what a
      # controller action ASSIGNED, and {RenderLocals} (#1047), which reads what a render site PASSED.
      #
      # Both run on the parent before any analysis — `#template_units_for_file` is called before the
      # engine has indexed anything — so neither may ask the typer a question, and both need the same four
      # answers off a Prism tree: which class declarations in this file are controllers, what their
      # qualified names are, which view directory each one owns, and which `def`s sit directly in the body.
      # Keeping one copy is what stops the two indexes from disagreeing about, say, whether
      # `module Admin; class UsersController` is `admin/users` — a disagreement that would be silent, since
      # each side would simply find nothing.
      #
      # It deliberately stops at the shapes {ControllerDiscoverer} already recognises. Anything a
      # controller does at runtime — `define_method`, a concern that adds actions on include — is not read
      # here and is not read there either.
      module ControllerScan
        module_function

        # Yields `[class_node, enclosing_namespace_segments]` for every `ClassNode` in the tree, with the
        # enclosing `module` chain accumulated. Mirrors {ControllerDiscoverer#walk_declarations}'s
        # qualification reduced to the two shapes that can carry an action: `class Admin::UsersController`
        # and `module Admin; class UsersController`.
        def each_controller(node, namespace, &)
          return unless node.is_a?(Prism::Node)

          if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
            yield node, namespace if node.is_a?(Prism::ClassNode)
            inner = namespace + constant_segments(node.constant_path)
            each_controller(node.body, inner, &) if node.body
            return
          end

          node.rigor_each_child { |child| each_controller(child, namespace, &) }
        end

        def constant_segments(path)
          case path
          when Prism::ConstantReadNode then [path.name.to_s]
          when Prism::ConstantPathNode then constant_segments(path.parent) + [path.name.to_s]
          else []
          end
        end

        # `["Admin", "UsersController"]` → `"admin/users"`. `ApplicationController` and the other abstract
        # bases are not excluded: an action they define really is inherited, and a template under their own
        # path simply never exists. nil for a class whose name is not a controller's.
        def controller_path(segments)
          return nil unless segments.last&.end_with?("Controller")

          parts = segments.map { |segment| underscore(segment) }
          parts[-1] = parts[-1].sub(/_controller\z/, "")
          return nil if parts[-1].empty?

          parts.join("/")
        end

        # The ASCII-only inflection this needs: a controller constant is a CamelCase identifier, and
        # nothing here has to invert an irregular plural (`ActiveSupport::Inflector` is the analysed
        # project's, not Rigor's).
        def underscore(segment)
          segment.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                 .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                 .downcase
        end

        # `{ :show => body_node }` for every `def` directly in the class body.
        def method_bodies(node)
          body = node.body
          return {} if body.nil?

          body.child_nodes.compact.filter_map do |child|
            next nil unless child.is_a?(Prism::DefNode) && child.receiver.nil?

            [child.name, child.body]
          end.to_h
        end

        # Every implicit-self `render` call node under `node`, at any depth.
        def each_render(node, &)
          return unless node.is_a?(Prism::Node)

          yield node if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :render
          node.rigor_each_child { |child| each_render(child, &) }
        end
      end
    end
  end
end
