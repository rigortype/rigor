# frozen_string_literal: true

require_relative "box"

module Rigor
  module Plugin
    # ADR-39 slice 5 — the selectable isolation strategy for target-library invocation. A plugin invokes a
    # pure method on a trusted target library (e.g. `ActiveSupport::Inflector.pluralize("post")`) through
    # {.call}; how much the invocation is isolated from Rigor's own process is a **configurable strategy**
    # (`RIGOR_PLUGIN_ISOLATION` env; the `exe/rigor` launcher maps `.rigor.yml`'s `plugins_isolation:` onto it
    # before re-exec). Three backends behind one interface:
    #
    # - `none` — load into the main space and call directly. Lowest cost; no isolation. Used as the fallback
    #   where fork is unavailable; fine because the invoked library is trusted + pure.
    # - `ruby_box` — call inside a {Box} (`Ruby::Box`, `RUBY_BOX=1`). Isolates core-class monkey-patches +
    #   lets gem versions coexist, but a native crash in the boxed work still takes the process down
    #   (in-process).
    # - `process` (**default**) — call in a forked worker ({Process}); returns data over a pipe. The
    #   strongest: a child crash (even `SIGSEGV`) is contained — the parent survives and declines. Higher cost
    #   (fork + IPC).
    #
    # All three answer with the method's return value, or raise {Unavailable} (never approximate) when the
    # target library cannot be reached in the chosen strategy — the caller's per-plugin rescue turns that into
    # silence, never a wrong fact.
    module Isolation
      class Unavailable < StandardError
      end

      STRATEGIES = %w[none ruby_box process].freeze

      module_function

      # The analyzed project's resolved bundler install root (e.g. `<project>/vendor/bundle`), or nil.
      # Set from the same `bundler.*` resolution that feeds bundle sig discovery (O4 / ADR-82 WD9) — by
      # the runner's pre-passes BEFORE any plugin `#prepare` runs, by `Environment.for_project` (which
      # also covers pool workers), and by `rigor plugins`' probe. When a target library cannot be
      # required from Rigor's own gem
      # environment (the standalone `gem install rigortype` case — activesupport is deliberately NOT a
      # runtime dependency), {require_with_target_bundle} falls back to requiring it from this bundle:
      # the analyzed Rails project always carries its own activesupport on disk, and loading the
      # project's locked copy is the higher-fidelity source of inflection rules anyway (ADR-79).
      def target_bundle_root
        @target_bundle_root
      end

      def target_bundle_root=(root)
        @target_bundle_root = root.nil? ? nil : File.expand_path(root.to_s)
      end

      # Requires `feature`, falling back to the analyzed project's bundler install tree. The fallback
      # appends every bundle gem's `full_require_paths` (from its RubyGems-generated `specifications/`
      # gemspec — the gem's own metadata, so nonstandard require paths like concurrent-ruby's
      # `lib/concurrent-ruby` resolve correctly) to `$LOAD_PATH` and retries. `$LOAD_PATH` is appended,
      # never prepended, and only on a failed require: Rigor's own activated gems keep precedence, and a
      # host environment that carries the gem never consults the bundle. (`Gem.paths` augmentation was
      # rejected — Bundler-locked processes silently ignore it.) Under the default `process` strategy the
      # mutation happens inside the forked worker only; under `none`/Direct it lands in the main space,
      # which is what that strategy means (documented tradeoff — the invoked library is trusted + pure).
      def require_with_target_bundle(feature, bundle_root)
        require feature
      rescue ::LoadError
        added = bundle_require_paths(bundle_root) - $LOAD_PATH
        raise if added.empty?

        $LOAD_PATH.concat(added)
        require feature
      end

      # Every bundle gem's require paths, newest version per gem name. Loading a `specifications/*.gemspec`
      # evaluates RubyGems-generated metadata of an installed third-party gem — the same trust level as
      # requiring the gem, which is what the caller is about to do.
      def bundle_require_paths(bundle_root)
        bundle_gem_dirs(bundle_root).flat_map do |gem_home|
          specs = Dir.glob(File.join(gem_home, "specifications", "*.gemspec"))
                     .filter_map { |file| Gem::Specification.load(file) }
          specs.group_by(&:name)
               .flat_map { |_, versions| versions.max_by(&:version).full_require_paths }
        end
      end

      # The RubyGems-shaped directories under a bundler install root: bundler nests them as
      # `<root>/ruby/<ruby-version>/`; a `BUNDLE_PATH` may also point directly at such a directory. Only
      # directories that actually carry a `specifications/` index are returned.
      def bundle_gem_dirs(bundle_root)
        return [] if bundle_root.nil? || bundle_root.to_s.empty?

        root = bundle_root.to_s
        (Dir.glob(File.join(root, "ruby", "*")) + [root])
          .select { |dir| File.directory?(File.join(dir, "specifications")) }
      end

      # The default strategy. `process` (a crash-contained forked worker) is the default: it isolates the
      # target library's monkey-patches + crashes from Rigor with no in-process contamination, and forks a
      # single persistent worker (not one per call). It falls back to `none` where fork is unavailable (see
      # {#backend}).
      DEFAULT = "process"

      # The configured strategy name (`RIGOR_PLUGIN_ISOLATION`), defaulting to {DEFAULT} for any unset /
      # unrecognised value.
      def strategy_name
        name = ENV["RIGOR_PLUGIN_ISOLATION"].to_s
        STRATEGIES.include?(name) ? name : DEFAULT
      end

      # Invokes `receiver.method(*args)` on a target library, requiring `feature` first, under the configured
      # isolation strategy. `receiver` is a constant name (String), `method` a Symbol from the caller's
      # allow-list, and `args` simple, Marshal-able / inspectable values (Strings) — never free input. Returns
      # the result, or raises {Unavailable}.
      def call(feature:, receiver:, method:, args:)
        backend.call(feature: feature, receiver: receiver, method: method, args: args)
      end

      # The backend module for the configured strategy. `process` (including the default) falls back to
      # `Direct` where `fork` is unavailable (Windows / JRuby) so inflection still works rather than silently
      # degrading — the libraries are trusted + pure, so the main-space fallback is acceptable when no
      # fork-based isolation can be had.
      def backend
        case strategy_name
        when "ruby_box" then RubyBox
        when "none" then Direct
        else Process.available? ? Process : Direct
        end
      end

      # `none` — load the trusted library into the main space and call it directly. No isolation; lowest
      # cost; the fork-unavailable fallback.
      module Direct
        module_function

        # NOTE: rescue classes are `::`-qualified throughout this file: `Rigor::Plugin::LoadError` (the
        # plugin-loading error) shadows the global `LoadError` in this lexical scope once plugin machinery
        # is loaded, so a bare `rescue LoadError` matches the WRONG class — the real `::LoadError` (a
        # ScriptError, not a StandardError) then escapes, kills the worker, and surfaces as an opaque
        # EOFError instead of the clean decline (the standalone-install regression of 2026-07-16).
        def call(feature:, receiver:, method:, args:)
          Isolation.require_with_target_bundle(feature, Isolation.target_bundle_root)
          Object.const_get(receiver).public_send(method, *args)
        rescue ::LoadError, ::NameError => e
          raise Unavailable, "#{receiver} could not be loaded (#{e.class}: #{e.message})"
        end
      end

      # `ruby_box` — call inside the shared {Box}. The expression is built from the fixed `receiver` /
      # allow-listed `method` and `inspect`-ed args (safe Ruby literals), so the box's `eval` carries no free
      # input.
      module RubyBox
        module_function

        def call(feature:, receiver:, method:, args:)
          raise Unavailable, "ruby_box isolation requested but Ruby::Box is not active (RUBY_BOX=1)" unless Box.enabled?
          raise Unavailable, "#{feature} could not be loaded into the Ruby::Box" unless Box.require_feature(feature)

          # `receiver` is a fixed constant name and `method` an allow-listed symbol; args are rendered via
          # `inspect` (safe Ruby literals), so the expression is e.g. `ActiveSupport::Inflector.pluralize("x")`
          # — no free input reaches the box's eval.
          rendered = args.map(&:inspect).join(", ")
          expression = "#{receiver}.#{method}(#{rendered})"
          Box.eval(expression)
        end
      end

      # `process` — run the call in a forked worker so a crash (even a C extension `SIGSEGV`) is contained:
      # the parent detects the dead worker (broken pipe / EOF) and declines instead of dying. A single
      # persistent worker handles all calls over a Marshal pipe pair.
      module Process
        module_function

        # Whether fork-based isolation can run on this platform.
        def available?
          ::Process.respond_to?(:fork)
        end

        def call(feature:, receiver:, method:, args:)
          raise Unavailable, "process isolation unavailable: fork is not supported" unless available?

          status, value = exchange([feature, receiver, method, args, Isolation.target_bundle_root])
          raise Unavailable, "process isolation worker error: #{value}" if status == :error

          value
        rescue Unavailable
          raise
        rescue ::StandardError => e
          # A dead worker surfaces as EOFError (Marshal.load) or Errno::EPIPE (Marshal.dump) — both
          # StandardError. The crash is contained: the parent resets the worker (respawn next call) and
          # declines.
          @worker = nil
          raise Unavailable, "process isolation worker failed (#{e.class})"
        end

        # Sends one request to the persistent worker and reads its reply. The request carries the
        # target-bundle root so the fallback require (see {Isolation.require_with_target_bundle}) happens
        # inside the worker — the parent's gem environment is never touched.
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

        # The child loop: read a `[feature, receiver, method, args, bundle_root]` request, require + call,
        # and write `[:ok, result]` or `[:error, message]`. EOF (parent gone) ends the loop.
        #
        # The rescue is `::`-qualified (see {Direct.call}) and covers `::ScriptError` so a failed require
        # (`::LoadError` is a ScriptError) replies with the clean `[:error, …]` decline instead of
        # silently killing the worker — the parent would otherwise see only an opaque EOFError.
        def run_worker_loop(req_r, res_w)
          loop do
            feature, receiver, method, args, bundle_root = Marshal.load(req_r) # rubocop:disable Security/MarshalLoad -- parent input
            reply =
              begin
                Isolation.require_with_target_bundle(feature, bundle_root)
                [:ok, Object.const_get(receiver).public_send(method, *args)]
              rescue ::StandardError, ::ScriptError => e
                [:error, "#{e.class}: #{e.message}"]
              end
            Marshal.dump(reply, res_w)
            res_w.flush
          end
        rescue ::EOFError
          # parent closed the request pipe — exit quietly
        ensure
          exit!(0)
        end
      end
    end
  end
end
