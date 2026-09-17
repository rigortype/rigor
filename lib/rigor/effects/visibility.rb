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
      # The markers that take arguments. `public` is not among them: `public :foo` re-opens a member
      # this module has no reason to track, since a name is only ever *added* to the answer.
      MARKERS = %i[private protected].freeze

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
          when Prism::DefNode then names << statement.name.to_s if region
          when Prism::CallNode
            region = region_after(statement, region)
            names.merge(targets(statement))
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

      # `private def foo` and `private :foo, :bar` — the argument forms.
      def targets(node)
        return NONE unless node.receiver.nil? && MARKERS.include?(node.name)

        Array(node.arguments&.arguments).filter_map do |argument|
          case argument
          when Prism::DefNode then argument.name.to_s
          when Prism::SymbolNode, Prism::StringNode then argument.unescaped
          end
        end
      end

      def bare?(node)
        node.receiver.nil? && node.arguments.nil? && node.block.nil?
      end

      private_class_method :region_after, :targets, :bare?
    end
  end
end
