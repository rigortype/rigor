# frozen_string_literal: true

require "prism"

module Rigor
  module Effects
    # The `private` / `protected` members a class body declared, read straight off its statement list in
    # source order (#1048).
    #
    # One reader, and it only ever declines: a UNIT {CalleeRule} rule. Rails' `action_methods` is a
    # controller's **public** instance methods, so a private helper is never implicitly rendered as
    # `<controller>/<helper>` — while a project that happens to ship a template of that name would
    # otherwise hand the template's effects to the helper. `private def card` beside
    # `app/views/users/card.html.erb` is the measured shape.
    #
    # Deliberately shallow and deliberately syntactic. It reads the class body's own top level, which is
    # where all three spellings appear in practice, and answers "public" for anything it cannot see —
    # `send(:private, :card)`, a visibility change in a `class_eval`, a concern that privatises on
    # include. Declining to decline leaves today's behaviour intact, which is the right direction for a
    # bit whose only power is to remove an edge.
    module Visibility
      # The markers whose ARGUMENT form names members. `public` is one of them and **subtracts**:
      # `private; def reopened; end; public :reopened` is a public action, and an answer that only ever
      # grew would mark it private and silently drop its implicit-render edge.
      HIDING = %i[private protected].freeze
      SHOWING = :public

      NONE = [].freeze
      private_constant :NONE

      module_function

      # The method names `body` — a class or module body — declared non-public.
      def non_public_names(body)
        statements = body.respond_to?(:body) ? Array(body.body) : NONE
        names = Set.new
        region = false
        statements.each do |statement|
          case statement
          # A `def self.x` is not the instance method a later `def x` defines, and the two share a name.
          # Recording the singleton would mark the instance method private, which is the same false
          # negative from the other side.
          when Prism::DefNode then names << statement.name.to_s if region && statement.receiver.nil?
          when Prism::CallNode
            region = region_after(statement, region)
            apply_targets(names, statement)
          end
        end
        names
      end

      # Whether a **bare** `private` / `protected` / `public` opened or closed the region. A marker with
      # arguments names specific members instead and leaves the region exactly as it was, which is what
      # lets `private def a` sit above a `public` region without closing it.
      def region_after(node, region)
        return region unless bare?(node)

        case node.name
        when :private, :protected then true
        when :public then false
        else region
        end
      end

      # `private def foo` / `private :foo, :bar`, and their inverse `public def foo` / `public :foo`.
      def apply_targets(names, node)
        return unless node.receiver.nil?
        return names.merge(argument_names(node)) if HIDING.include?(node.name)
        return unless node.name == SHOWING

        argument_names(node).each { |name| names.delete(name) }
      end

      def argument_names(node)
        arguments = node.arguments&.arguments
        return NONE if arguments.nil? || arguments.empty?

        arguments.filter_map do |argument|
          case argument
          when Prism::DefNode then argument.name.to_s
          when Prism::SymbolNode, Prism::StringNode then argument.unescaped
          end
        end
      end

      def bare?(node)
        node.receiver.nil? && node.arguments.nil? && node.block.nil?
      end

      private_class_method :region_after, :apply_targets, :argument_names, :bare?
    end
  end
end
