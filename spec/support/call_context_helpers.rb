# frozen_string_literal: true

require "rigor/inference/method_dispatcher/call_context"

# Shared helper for the dispatch-tier unit specs. Every tier entry point
# takes a `CallContext` (Finding 3 interface unification); `cc` builds one
# from the call quartet so specs need not spell out the wider context
# fields they do not exercise.
module CallContextHelpers
  def cc(receiver:, method_name:, args:, **rest)
    Rigor::Inference::MethodDispatcher::CallContext.build(
      receiver: receiver, method_name: method_name, args: args, **rest
    )
  end
end

RSpec.configure do |config|
  config.include CallContextHelpers
end
