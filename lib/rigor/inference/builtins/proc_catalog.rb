# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Proc` / `Method` / `UnboundMethod` catalog. Singleton —
      # load once, consult during dispatch.
      #
      # The three callable carriers are imported together because
      # `Init_Proc` registers them in a single C init block. They
      # share the same fundamental hazard at the catalog tier:
      # most of their public methods invoke the wrapped Ruby code
      # (the proc body, the bound method's receiver, …) and that
      # code can do anything — read mutable state, call I/O, return
      # different values on successive calls. The static C-body
      # classifier marks these `:leaf` because the C functions
      # themselves do not call `rb_funcall*` / `rb_yield` directly
      # (they delegate through the VM's optimised call paths and
      # method-entry table), but folding any of them at compile
      # time would freeze a value the runtime never actually
      # produces twice.
      #
      # The blocklist below errs aggressively on the side of
      # caution: a hypothetical future `Constant<Proc>` /
      # `Constant<Method>` / `Constant<UnboundMethod>` carrier
      # would have very little to gain from these folds and a
      # great deal to lose if user code ran behind the analyzer's
      # back. Reflective readers (`#arity`, `#parameters`,
      # `#source_location`, `#name`, `#owner`, `#receiver`) remain
      # foldable; the RBS tier still resolves return types for
      # the blocklisted methods so callers do not lose precision.
      PROC_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/proc.yml",
          __dir__
        ),
        mutating_selectors: {
          "Proc" => Set[
            # `#call` / `#[]` / `#===` / `#yield` invoke the proc
            # body. The C body routes through
            # `OPTIMIZED_METHOD_TYPE_CALL` (a VM fast path the
            # classifier cannot see into); the proc body can do
            # anything — read globals, mutate captured locals,
            # raise. MUST decline to fold.
            :call,
            :[],
            :===,
            :yield,
            # `#curry` / `#<<` / `#>>` allocate a fresh `Proc`
            # that closes over the receiver (and, for `<<` /
            # `>>`, over the argument). Folding would freeze a
            # specific `Proc` instance whose identity the runtime
            # never actually produces (object_id differs every
            # call), so the catalog tier declines.
            :curry,
            :<<,
            :>>,
            # `#to_proc` returns `self` for `Proc` (cheap), but
            # blocking it keeps the rule shape uniform across the
            # three callable carriers (Method#to_proc allocates a
            # fresh `Proc`).
            :to_proc,
            # Identity-based equality and hashing: `#hash` is
            # derived from the underlying ISeq pointer; `#==` /
            # `#eql?` compare ISeq + binding. Folding to a
            # `Constant<Integer>` / `Constant<bool>` would freeze
            # an answer that depends on memory layout. Defensive.
            :hash,
            :==,
            :eql?,
            # `initialize_copy` is blocklisted by convention so a
            # hypothetical future `Constant<Proc>` carrier cannot
            # fold an aliasing copy through the catalog.
            :initialize_copy
          ],
          "Method" => Set[
            # `#call` / `#[]` / `#===` invoke the bound method.
            # Same hazard as `Proc#call`: arbitrary user code,
            # arbitrary side effects.
            :call,
            :[],
            :===,
            # `#curry` / `#<<` / `#>>` allocate a fresh `Proc`
            # that closes over the bound method.
            :curry,
            :<<,
            :>>,
            # `#to_proc` allocates a fresh `Proc` wrapping the
            # bound method — folding would freeze its object_id.
            # The classifier already marks it `:block_dependent`,
            # but the explicit entry keeps the intent obvious.
            :to_proc,
            # `#unbind` allocates a fresh `UnboundMethod` whose
            # identity differs every call.
            :unbind,
            # Identity-based equality and hashing.
            :hash,
            :==,
            :eql?,
            # `initialize_copy` is blocklisted by convention.
            :initialize_copy
          ],
          "UnboundMethod" => Set[
            # `#bind` allocates a fresh `Method` whose object_id
            # differs every call; `#bind_call` invokes the bound
            # method (already classified `:block_dependent`).
            :bind,
            :bind_call,
            # Identity-based equality and hashing.
            :hash,
            :==,
            :eql?,
            # `initialize_copy` is blocklisted by convention.
            :initialize_copy
          ]
        }
      )
    end
  end
end
