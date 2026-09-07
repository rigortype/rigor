# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    # ADR-82 — the effective {DynamicOrigin} cause of a receiver *expression*, unifying the two provenance
    # lookups so a chain and a bare variable resolve the same way:
    #
    # - the cause recorded on the expression's own node (`Scope#dynamic_origins`), covering a call node whose
    #   dispatch recorded a cause (WD2's user-method tiers, or WD6's chain inheritance), and
    # - for a bare local / instance-variable read, the cause propagated from its binding (WD1's
    #   `Scope#local_origins` / `#ivar_origins`) — the read node itself carries none, the cause was recorded
    #   on the assignment's rhs.
    #
    # Consulted by `ProtectionScanner` (to label a hole) and `ExpressionTyper` (WD6 — to inherit a Dynamic
    # receiver's cause onto the call it produces, so provenance survives a method chain).
    module OriginLookup
      module_function

      # @rbs node: Prism::Node? -- The receiver expression's node (nil for an implicit-self receiver)
      # @rbs return: Symbol? -- The effective dynamic-origin cause, or nil when none is known
      def origin_for(scope, node)
        return nil if node.nil?

        scope.dynamic_origins[node] || propagated(scope, node)
      end

      def propagated(scope, node)
        case node
        when Prism::LocalVariableReadNode then scope.local_origin(node.name)
        when Prism::InstanceVariableReadNode then scope.ivar_origin(node.name)
        end
      end
    end
  end
end
