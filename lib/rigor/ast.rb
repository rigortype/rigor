# frozen_string_literal: true

module Rigor
  # Synthetic AST nodes accepted by Rigor::Scope#type_of alongside real
  # Prism nodes. Rigor::AST::Node is a documentation-only marker module
  # that production code uses to detect virtual-node arguments. Concrete
  # virtual node classes include Rigor::AST::Node and provide whatever
  # node-specific data the engine needs to translate them into a
  # Rigor::Type.
  #
  # The contract for virtual nodes lives in
  # docs/internal-spec/inference-engine.md; the rationale and the rejected
  # alternative of specialising type classes for operator-method dispatch
  # live in docs/adr/4-type-inference-engine.md.
  module AST
    # Marker module included by every synthetic node. Carries no behaviour.
    module Node
    end
  end
end

require_relative "ast/type_node"
