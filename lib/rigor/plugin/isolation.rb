# frozen_string_literal: true

require_relative "box"

module Rigor
  module Plugin
    # ADR-39 slice 5 — the selectable isolation strategy for target-library
    # invocation. A plugin invokes a pure method on a trusted target
    # library (e.g. `ActiveSupport::Inflector.pluralize("post")`) through
    # {.call}; how much the invocation is isolated from Rigor's own process
    # is a **configurable strategy** (`RIGOR_PLUGIN_ISOLATION` env; the
    # `exe/rigor` launcher maps `.rigor.yml`'s `plugins_isolation:` onto it
    # before re-exec). Three backends behind one interface:
    #
    # - `none` (**default**) — load into the main space and call directly.
    #   Lowest cost; no isolation. Fine for the common case because the
    #   invoked library is trusted + pure.
    # - `ruby_box` — call inside a {Box} (`Ruby::Box`, `RUBY_BOX=1`). Isolates
    #   core-class monkey-patches + lets gem versions coexist, but a native
    #   crash in the boxed work still takes the process down (in-process).
    # - `process` — call in a forked worker ({Process}); returns data over a
    #   pipe. The strongest: a child crash (even `SIGSEGV`) is contained —
    #   the parent survives and declines. Higher cost (fork + IPC).
    #
    # All three answer with the method's return value, or raise
    # {Unavailable} (never approximate) when the target library cannot be
    # reached in the chosen strategy — the caller's per-plugin rescue turns
    # that into silence, never a wrong fact.
    module Isolation
      class Unavailable < StandardError
      end

      STRATEGIES = %w[none ruby_box process].freeze

      module_function

      # The default strategy. `process` (a crash-contained forked worker)
      # is the default: it isolates the target library's monkey-patches +
      # crashes from Rigor with no in-process contamination, and forks a
      # single persistent worker (not one per call). It falls back to
      # `none` where fork is unavailable (see {#backend}).
      DEFAULT = "process"

      # The configured strategy name (`RIGOR_PLUGIN_ISOLATION`), defaulting
      # to {DEFAULT} for any unset / unrecognised value.
      def strategy_name
        name = ENV["RIGOR_PLUGIN_ISOLATION"].to_s
        STRATEGIES.include?(name) ? name : DEFAULT
      end

      # Invokes `receiver.method(*args)` on a target library, requiring
      # `feature` first, under the configured isolation strategy. `receiver`
      # is a constant name (String), `method` a Symbol from the caller's
      # allow-list, and `args` simple, Marshal-able / inspectable values
      # (Strings) — never free input. Returns the result, or raises
      # {Unavailable}.
      def call(feature:, receiver:, method:, args:)
        backend.call(feature: feature, receiver: receiver, method: method, args: args)
      end

      # The backend module for the configured strategy. `process`
      # (including the default) falls back to `Direct` where `fork` is
      # unavailable (Windows / JRuby) so inflection still works rather than
      # silently degrading — the libraries are trusted + pure, so the
      # main-space fallback is acceptable when no fork-based isolation can
      # be had.
      def backend
        case strategy_name
        when "ruby_box" then RubyBox
        when "none" then Direct
        else Process.available? ? Process : Direct
        end
      end

      # `none` — load the trusted library into the main space and call it
      # directly. No isolation; lowest cost; the current default behaviour.
      module Direct
        module_function

        def call(feature:, receiver:, method:, args:)
          require feature
          Object.const_get(receiver).public_send(method, *args)
        rescue LoadError, NameError => e
          raise Unavailable, "#{receiver} could not be loaded (#{e.class}: #{e.message})"
        end
      end

      # `ruby_box` — call inside the shared {Box}. The expression is built
      # from the fixed `receiver` / allow-listed `method` and `inspect`-ed
      # args (safe Ruby literals), so the box's `eval` carries no free
      # input.
      module RubyBox
        module_function

        def call(feature:, receiver:, method:, args:)
          raise Unavailable, "ruby_box isolation requested but Ruby::Box is not active (RUBY_BOX=1)" unless Box.enabled?
          raise Unavailable, "#{feature} could not be loaded into the Ruby::Box" unless Box.require_feature(feature)

          # `receiver` is a fixed constant name and `method` an allow-listed
          # symbol; args are rendered via `inspect` (safe Ruby literals), so
          # the expression is e.g. `ActiveSupport::Inflector.pluralize("x")`
          # — no free input reaches the box's eval.
          rendered = args.map(&:inspect).join(", ")
          expression = "#{receiver}.#{method}(#{rendered})"
          Box.eval(expression)
        end
      end

      # `process` — run the call in a forked worker so a crash (even a C
      # extension `SIGSEGV`) is contained: the parent detects the dead
      # worker (broken pipe / EOF) and declines instead of dying. A single
      # persistent worker handles all calls over a Marshal pipe pair.
      module Process
        module_function

        # Whether fork-based isolation can run on this platform.
        def available?
          ::Process.respond_to?(:fork)
        end

        def call(feature:, receiver:, method:, args:)
          raise Unavailable, "process isolation unavailable: fork is not supported" unless available?

          status, value = exchange([feature, receiver, method, args])
          raise Unavailable, "process isolation worker error: #{value}" if status == :error

          value
        rescue Unavailable
          raise
        rescue StandardError => e
          # A dead worker surfaces as EOFError (Marshal.load) or Errno::EPIPE
          # (Marshal.dump) — both StandardError. The crash is contained: the
          # parent resets the worker (respawn next call) and declines.
          @worker = nil
          raise Unavailable, "process isolation worker failed (#{e.class})"
        end

        # Sends one request to the persistent worker and reads its reply.
        def exchange(request)
          w = worker
          Marshal.dump(request, w[:req])
          w[:req].flush
          Marshal.load(w[:res]) # rubocop:disable Security/MarshalLoad -- worker output, not untrusted input
        end

        def worker
          @worker ||= spawn_worker
        end

        def spawn_worker
          req_r, req_w = IO.pipe
          res_r, res_w = IO.pipe
          pid = fork_worker(req_r, req_w, res_r, res_w)
          req_r.close
          res_w.close
          { pid: pid, req: req_w, res: res_r }
        end

        def fork_worker(req_r, req_w, res_r, res_w)
          ::Process.fork do
            req_w.close
            res_r.close
            run_worker_loop(req_r, res_w)
          end
        end

        # The child loop: read a `[feature, receiver, method, args]`
        # request, require + call, and write `[:ok, result]` or
        # `[:error, message]`. EOF (parent gone) ends the loop.
        def run_worker_loop(req_r, res_w)
          loop do
            feature, receiver, method, args = Marshal.load(req_r) # rubocop:disable Security/MarshalLoad -- parent input
            reply =
              begin
                require feature
                [:ok, Object.const_get(receiver).public_send(method, *args)]
              rescue StandardError, LoadError => e
                [:error, "#{e.class}: #{e.message}"]
              end
            Marshal.dump(reply, res_w)
            res_w.flush
          end
        rescue EOFError
          # parent closed the request pipe — exit quietly
        ensure
          exit!(0)
        end
      end
    end
  end
end
