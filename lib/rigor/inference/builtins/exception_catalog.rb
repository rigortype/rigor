# frozen_string_literal: true

require_relative "method_catalog"

module Rigor
  module Inference
    module Builtins
      # `Exception` catalog. Singleton — load once, consult during
      # dispatch.
      #
      # Exception is the base of every Ruby error class (RuntimeError,
      # StandardError, KeyError, …). The Init_Exception block in
      # `references/ruby/error.c` registers the entire hierarchy in
      # one pass, so the YAML carries 27 classes — but only the base
      # `Exception` row is wired into `CATALOG_BY_CLASS` for v0.0.5.
      # A `RuntimeError` receiver hits the Exception arm via
      # `is_a?(Exception)` and the catalog answers with the base-class
      # entries; subclass-specific methods (`KeyError#receiver`,
      # `NameError#name`, …) intentionally miss the lookup until a
      # later slice routes per-subclass class_names.
      #
      # The catalog tier here is *defence in depth* — every base
      # method that could plausibly fold has been weighed against the
      # robustness principle (strict on returns) and either left
      # `:dispatch` / `:mutates_self` (in which case the catalog
      # already declines) or blocklisted because the static classifier
      # missed an indirect side effect. The remaining `:leaf` method
      # that DOES fold is `#cause`, a pure accessor.
      EXCEPTION_CATALOG = MethodCatalog.new(
        path: File.expand_path(
          "../../../../data/builtins/ruby_core/exception.yml",
          __dir__
        ),
        mutating_selectors: {
          "Exception" => Set[
            # `exc_initialize` writes `mesg` / `backtrace` ivars on
            # self via `rb_ivar_set` — the C-body classifier missed
            # the indirect mutator because the helpers are not in
            # its regex. Blocklisted so a hypothetical future
            # `Constant<Exception>` carrier cannot fold an aliasing
            # constructor through the catalog.
            :initialize,
            # `exc_exception` either returns self (no-arg) or calls
            # `rb_obj_clone` + `exc_initialize_internal` on the
            # clone — the clone branch mutates fresh state through
            # the same indirect helpers as `:initialize`. Conservative
            # blocklist; the cost is one folded no-arg call.
            :exception,
            # `exc_detailed_message` formats with platform / locale
            # data (highlight markers depend on `$stderr.tty?` via
            # the keyword arg default and `rb_io_tty_p`). Folding
            # would freeze a value that depends on the calling
            # process's stderr state.
            :detailed_message,
            # `exc_backtrace` reads the captured frame list, which
            # depends on where the exception was raised — context
            # the static fold tier cannot reproduce.
            :backtrace,
            # Same rationale as `:backtrace`; `Thread::Backtrace::Location`
            # objects are runtime artefacts.
            :backtrace_locations,
            # `exc_set_backtrace` mutates the @backtrace ivar via
            # `rb_ivar_set` — another indirect mutator the classifier
            # missed.
            :set_backtrace,
            # `initialize_copy` is blocklisted by convention so a
            # hypothetical future `Constant<Exception>` carrier
            # cannot fold an aliasing copy through the catalog.
            :initialize_copy,
            # Defensive entries for the universal mutation surface.
            # Object-identity hashing on a constant carrier is fine,
            # but `eql?` on Exception delegates to `==` (dispatch);
            # blocking both keeps the constant-fold tier honest.
            :hash,
            :eql?
          ],
          # `Exception.to_tty?` (singleton) calls
          # `rb_io_tty_p($stderr)`; its return depends on the
          # process's stderr state at runtime, never on compile-time
          # arguments. The catalog tier today only consults
          # `mutating_selectors` for instance-receiver dispatches via
          # `CATALOG_BY_CLASS`, so this row is documentation-grade —
          # it records the soundness rationale for any future slice
          # that wires the singleton path through the catalog.
          "Exception.singleton" => Set[
            :to_tty?
          ]
        }
      )
    end
  end
end
