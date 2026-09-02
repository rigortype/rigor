# frozen_string_literal: true

require "rigor/plugin"

require_relative "actionpack/analyzer"
require_relative "actionpack/effects"
require_relative "actionpack/controller_discoverer"
require_relative "actionpack/controller_index"

module Rigor
  module Plugin
    # rigor-actionpack — validates Action Pack DSL calls in controller files.
    #
    # **Phase 4 of the Action Pack plugin family** (route-helper consumption). Reads the `:helper_table`
    # fact published by `rigor-rails-routes` (ADR-9 cross-plugin API) and validates every implicit-self
    # `*_path` / `*_url` call inside files under `controller_search_paths` (default `app/controllers`).
    #
    # Tier 2 of the [Rails plugins roadmap](../../../../docs/design/20260508-rails-plugins-roadmap.md).
    # Phase 1 (strong-parameters → AR column validation), Phase 2 (filter chains), and Phase 3 (render
    # targets) ship as separate slices; each phase composes additively under the same plugin id.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-rails-routes      # producer (must come first
    #                                       # in `Configuration#plugins`
    #                                       # ordering, OR the loader's
    #                                       # ADR-9 topo sort handles it)
    #       - gem: rigor-actionpack
    #         config:
    #           controller_search_paths: ["app/controllers"]   # default; optional
    #
    # ## What it checks
    #
    # - **Helper existence** — every `*_path` / `*_url` call inside a controller file is looked up in
    #   the helper table. Missing entries emit `unknown-helper` with a `DidYouMean` suggestion drawn
    #   from the table.
    # - **Helper arity** — the call's positional-argument count is matched against the helper's
    #   recorded arity (a trailing `KeywordHashNode` like `users_path(format: :json)` is excluded; same
    #   convention `rigor-rails-routes` uses). Mismatches emit `wrong-helper-arity`.
    # - **Trace** — recognised helpers also emit a `helper-call` info diagnostic naming the action and
    #   path, mirroring the trace shape of the upstream plugin.
    #
    # ## Limitations
    #
    # - Implicit-self calls only. `Rails.application.routes.url_helpers.users_path` and other
    #   explicit-receiver shapes are passed through; they're rare in controller code and the helper
    #   table doesn't include any extra context to validate them.
    # - Files outside `controller_search_paths` are skipped. The plugin doesn't try to detect "is this
    #   a controller?" by class hierarchy — Phase 1's strong-parameters work needs that, so it lives
    #   there. Phase 4's job is the single-purpose helper check.
    # - When `rigor-rails-routes` is not installed (or its helper table is empty), Phase 4 silently
    #   degrades to a no-op. No load-error diagnostic is emitted; the user gets the "no checks
    #   happened" failure mode rather than a wall of "is this configured right?" warnings.
    class Actionpack < Rigor::Plugin::Base
      manifest(
        id: "actionpack",
        # ADR-37: the four phases (helper / filter / render / strong-params) run per-call over the
        # engine-owned walk; the enclosing controller is read from the node-rule `NodeContext`
        # ancestors. Nested-module qualification is preserved — `module Admin; class
        # DomainBlocksController` resolves as `Admin::DomainBlocksController` (matching the
        # `ControllerDiscoverer`), so render paths and filter-chain validation on nested controllers are
        # correct.
        # Bumped 2026-09-02 (#534 "same lane") — the request predicates and the FlashHash chain join the
        # typed surface. `0.9.0`'s successor is `1.0.0`, not `0.10.0`: AGENTS.md's single-digit rule binds
        # recursively at every position, and it applies here because a manifest version is a cache key
        # rather than a gem release (so the no-autonomous-bump rule does not).
        # Bumped 2026-09-02 (#621) — a reopened controller's `def`s are UNIONed rather than clobbered by
        # the later file in the glob, so a cached 1.0.0 index can be missing the filter targets the merge
        # restores.
        version: "1.1.0",
        description: "Validates Action Pack route-helper calls and filter chains inside controllers, and types the request-context readers (`params` / `session` / `request` / `flash`) and their chains.",
        config_schema: {
          "controller_search_paths" => { kind: :array, default: ["app/controllers"] },
          "view_search_paths" => { kind: :array, default: ["app/views"] }
        },
        consumes: [
          { plugin_id: "rails-routes", name: :helper_table, optional: true },
          { plugin_id: "activerecord", name: :model_index, optional: true }
        ],
        # ADR-103 WD10 / WD14 (#387) — see {Effects} for what each row is and why.
        effect_root: "rails",
        effect_labels: %w[
          rails.response.write rails.session.read rails.session.write rails.cookie.write rails.flash.write
        ],
        effect_attributions: Effects.attributions,
        effect_entry_points: Effects.entry_points
      )

      # Phase 2 cached producer — the controller index built from `controller_search_paths`. `watch:`
      # (ADR-60 WD3) covers every `.rb` file under those roots so the cache invalidates when a
      # controller is added, removed, or edited; the discoverer's in-block `io_boundary` reads are
      # captured into the dependency descriptor too, so no explicit priming is needed.
      producer :controller_index, watch: -> { [[@controller_search_paths, "**/*.rb"]] } do |_params|
        ControllerDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @controller_search_paths
        ).discover
      end

      def init(_services)
        @controller_search_paths = Array(config.fetch("controller_search_paths")).map(&:to_s)
        @view_search_paths = Array(config.fetch("view_search_paths")).map(&:to_s)
      end

      # ADR-37 — the four Action Pack phases run per-call over the engine-owned walk. Each rule gates on
      # `controller_file?(path)` (the plugin only validates files under `controller_search_paths`,
      # exactly as the former `diagnostics_for_file` top-level guard did), then delegates to a per-node
      # `Analyzer.*_violations_for` and positions each location-free `Violation` with `Base#diagnostic`.
      # The filter / render phases read the enclosing controller from the node-rule `NodeContext`
      # ancestors (its fifth block argument).

      # Phase 4 — route-helper consumption. `:helper_table` is rigor-rails-routes's published fact
      # (ADR-9), read lazily via `read_fact`.
      node_rule Prism::CallNode do |node, _scope, path|
        next [] unless controller_file?(path)

        table = read_fact(plugin_id: "rails-routes", name: :helper_table)
        next [] if table.nil? || table.empty?

        diagnostics_for(Analyzer.helper_violations_for(call_node: node, helper_table: table), path: path, node: node)
      end

      # Phase 2 — filter-chain validation. Skips silently when the controller index is absent or
      # doesn't recognise the enclosing class.
      node_rule Prism::CallNode do |node, _scope, path, _fc, context|
        next [] unless controller_file?(path)

        index = producer_value(:controller_index)
        next [] if index.nil? || index.empty?

        diagnostics_for(
          Analyzer.filter_violations_for(call_node: node, ancestors: context.ancestors, controller_index: index),
          path: path, node: node
        )
      end

      # Phase 3 — render-target validation against the configured `view_search_paths`. Recognised purely
      # from the call site + the enclosing controller name, so no per-controller pre-discovery is
      # needed; the controller index is consulted only to suppress gem-shipped-view false positives.
      node_rule Prism::CallNode do |node, _scope, path, _fc, context|
        next [] unless controller_file?(path)

        diagnostics_for(
          Analyzer.render_violations_for(
            call_node: node, ancestors: context.ancestors, path: path,
            view_search_roots: @view_search_paths, controller_index: producer_value(:controller_index)
          ),
          path: path, node: node
        )
      end

      # Phase 1 — strong-parameter validation. Reads the `:model_index` fact from the cross-plugin fact
      # store (published by rigor-activerecord) and validates every `params.require(:user).permit(:name,
      # :email)` chain against the User model's column list.
      node_rule Prism::CallNode do |node, _scope, path|
        next [] unless controller_file?(path)

        index = read_fact(plugin_id: "activerecord", name: :model_index)
        next [] if index.nil? || index.empty?

        diagnostics_for(Analyzer.permit_violations_for(call_node: node, model_index: index), path: path, node: node)
      end

      # Phase 5 (2026-07-04) — type the implicit-self request-context readers (`params`, `session`,
      # `request`, `flash`, `cookies`) inside controllers. The typing-obstacle probe
      # (docs/notes/20260704-rails-coverage-onboarding-carrier-trap.md, obstacle O3) found `params`
      # typing to `Dynamic[top]` the single largest protection-coverage hole on real Rails apps:
      # `params[:x]` is the #1 dispatch cluster (redmine app+lib: `[]` 2378 sites) and `session[:x] =` a
      # large share of the `[]=` cluster, all unprotected because the receiver is Dynamic.
      #
      # Each returns a bare nominal with NO bundled RBS on purpose. That makes the reader a *concrete*
      # receiver (so `coverage --protection` counts the site as protected and the dispatch resolves
      # against a named class) while its method surface stays engine-lenient — Rigor does not fire
      # `undefined-method` on a class it has no RBS for, so `params.require(...).permit(...)`,
      # `session.delete(:x)`, `request.xhr?`, and every other method on these stay FP-safe. Shipping a
      # partial RBS would re-introduce the carrier-additivity trap (a declared class drops every member
      # the RBS omits → false `undefined-method`). ADR-5: this types the container, never the caller's
      # argument, so the values stay lenient.
      REQUEST_CONTEXT_READER_TYPES = {
        params: "ActionController::Parameters",
        session: "ActionDispatch::Request::Session",
        request: "ActionDispatch::Request",
        flash: "ActionDispatch::Flash::FlashHash",
        cookies: "ActionDispatch::Cookies::CookieJar"
      }.freeze

      dynamic_return methods: REQUEST_CONTEXT_READER_TYPES.keys do |call_node, scope|
        next nil unless call_node.is_a?(Prism::CallNode)
        next nil unless call_node.receiver.nil?   # the implicit-self reader
        next nil unless call_node.arguments.nil?  # `params`, not `params(x)`
        next nil unless controller_scope?(scope)

        class_name = REQUEST_CONTEXT_READER_TYPES[call_node.name]
        next nil if class_name.nil?

        Rigor::Type::Combinator.nominal_of(class_name)
      end

      # Phase 5b (2026-07-10) — keep the strong-parameters fluent chain typed. `params` types to
      # `ActionController::Parameters` (above), but the chained `params.require(:user).permit(:name)` /
      # `params.permit(...)` calls returned `Dynamic` at the first hop (Parameters ships no bundled RBS,
      # so a call on it resolves lenient-to-Dynamic), leaking every downstream site (`.permit`, `.to_h`,
      # `.each`) to unprotected. These three methods return another `Parameters`, so gate on a
      # `Parameters` receiver and re-type the result as the same lenient nominal — the chain stays a
      # concrete receiver end-to-end and `coverage --protection` counts the sites as protected.
      #
      # `require` may return a scalar for a flat key at runtime (`params.require(:id) → String`), but
      # typing it as the RBS-less `Parameters` is FP-safe by the same argument as the readers: every
      # method on a Parameters value stays engine-lenient (no `undefined-method`), and this types the
      # container only, never a caller's argument (ADR-5). The GitLab strong-params survey (108 leaked
      # `.permit` sites) is the demand.
      # Issue #534 — `expect` (Rails 8's require+permit) and `slice` joined 2026-09-01, from the corpus
      # sweep's pair counts (63 and 38 sites on mastodon). Both share `require`'s safety shape: they
      # never return nil (`expect` raises like `require`; `slice` always returns a Parameters), so the
      # non-nil lenient nominal cannot fold a flow rule wrong.
      #
      # ## The admission rule for this table
      #
      # A method belongs here **iff its Rails implementation returns an `ActionController::Parameters`
      # on every path** — either a fresh `new_instance_with_inherited_permitted_status(...)` or `self`.
      # That is a stronger bar than "usually returns Parameters", and it is the bar that keeps the
      # entry FP-safe, because the RBS-less nominal buys leniency on the *method surface* only:
      #
      # - Method-surface rules DO decline on it. `call.undefined-method` bails at
      #   `Rigor::Reflection.rbs_class_known?` (lib/rigor/analysis/check_rules.rb:720) because Rigor
      #   ships no RBS for Parameters, and the argument / arity rules gate on the same predicate
      #   (:1151, :2126). So `params.slice(:a).whatever_rails_adds` never fires, and a scalar-shaped
      #   use of a Parameters-typed value (`.to_i`, `.strip`, string interpolation) resolves lenient
      #   -to-Dynamic rather than to a diagnostic.
      # - **Flow rules do NOT.** Truthiness folding, ternary arm selection and `.nil?` folding key on
      #   the type being *nil-free*, not on whether Rigor knows its methods. A non-nil nominal standing
      #   in for a value that is nil at runtime is a wrong precise type, and the folds it licenses are
      #   real diagnostics on correct code. This is why the table admits only never-nil methods, and
      #   why `#[]` is excluded below.
      #
      # Return contracts verified against rails v8.1.0.beta1
      # (`actionpack/lib/action_controller/metal/strong_parameters.rb`). Deliberately excluded even
      # though they are Parameters-shaped: `compact!` (`self if @parameters.compact!` — returns nil
      # when nothing changed, :1038); `select` / `reject` / `filter` / `transform_keys` /
      # `transform_values` (`to_enum(...)` without a block, so the answer depends on the call's block
      # argument, :1004/:1018/:934/:917); `select!` / `keep_if`, whose doc comment ("returns nil if no
      # changes were made") contradicts its body (`self`, :1010) — a contradiction that could resolve
      # either way on a future Rails, and the demand does not justify betting on it; `dig` / `fetch` /
      # `to_h` / `to_unsafe_h`, which return a caller value, nil, or a HashWithIndifferentAccess.
      # `reject!` / `delete_if` / `compact_blank!` DO return `self` on every path (:1024/:1028/:1050)
      # and are admissible under the same argument — deferred only to keep this change at the
      # reviewed set; admit them with the next batch.
      #
      # ## Why `Parameters#[]` is NOT here (issue #534 item 1, adjudicated 2026-09-01)
      #
      # `#[]` is the single largest named-receiver pair on both survey apps (redmine 581, mastodon
      # ~475), so it is the entry with by far the most to gain — and both typings of it were measured
      # on a fixture controller of ordinary Rails idioms before being rejected:
      #
      # - **`#[] -> Parameters` (non-nil).** Types the whole chain (`params[:a][:b][:c]` resolves), but
      #   the non-nil nominal is a *wrong* precise type at a missing key, and the flow rules act on it.
      #   Every `params[:k]` condition becomes always-truthy, so a ternary over one folds to its true
      #   arm: `mode = params[:full] ? :full : :short` types `mode` as `:full`, and the live guard
      #   `return if mode == :short` draws `flow.always-truthy-condition` — a diagnostic on a branch
      #   the program really takes. The same fold proves `if url.nil?` unreachable and types its body
      #   `bot`. This reproduces the withdrawal measured on five working redmine/mastodon controllers.
      #   (A shape like `x = params[:flag] ? nil : "a"; x.upcase` also changes answer, but it is a true
      #   positive both before and after — `String | nil` genuinely can be nil — so it is evidence of
      #   the fold, not of an FP. The two shapes above are the ones that are silent today and wrong
      #   under this typing, which is why they are what the spec pins.)
      # - **`#[] -> Parameters | nil`.** Fixes every fold above (no ternary collapse, no `bot` branch)
      #   and still carries the chain — `params[:user][:name]` types `Parameters?` and
      #   `params[:user].permit(:name)` types `Parameters`, because the dispatcher strips the nil arm
      #   for the receiver gate. Idiomatic *chained* reads stay silent too: `call.possible-nil-receiver`
      #   restricts itself to `Prism::LocalVariableReadNode` receivers (`CheckRules#nil_receiver_diagnostic`'s local-read restriction), so
      #   `params[:q].strip` cannot fire. What it does fire on is the assigned form — `q = params[:q];
      #   q.strip` — at **error** severity, once per unguarded use. Guarded forms (`return if q.nil?`,
      #   `if q`, `q&.strip`, `|| ""`) all narrow correctly and stay silent, so this is not a broken
      #   rule; it is the rule working, on a shape working Rails controllers use constantly. Adopting
      #   it would put an error on correct code in exchange for a coverage metric.
      #
      # Both trades buy protection-coverage with false positives, which inverts the project's ordering
      # of those two goods (AGENTS.md: "false positives outrank worst-case static reading"). `#[]`
      # therefore stays Dynamic, and three control specs pin that answer with the exact probe shapes
      # above — two negatives, each verified to go RED under the typing it rejects, plus a must-fire
      # sibling proving the fixture can raise both rules. Reopening it needs a *rules-level* change
      # first — a receiver-position nullable the flow rules read as unknown rather than as nil — not
      # another plugin table row.
      STRONG_PARAMS_CHAIN_METHODS = %i[
        require permit permit! expect slice
        except without extract! slice!
        merge merge! reverse_merge reverse_merge! with_defaults with_defaults!
        compact compact_blank deep_dup
      ].freeze

      dynamic_return receivers: [REQUEST_CONTEXT_READER_TYPES[:params]], methods: STRONG_PARAMS_CHAIN_METHODS do |call_node, _scope|
        next nil unless call_node.is_a?(Prism::CallNode)

        Rigor::Type::Combinator.nominal_of(REQUEST_CONTEXT_READER_TYPES[:params])
      end

      # Phase 5c (2026-09-02, issue #534 "same lane") — the rest of the request-context surface the
      # corpus sweep measured after the #578 / #585 batch: `request.post?` 28 and `request.xhr?` 27 on
      # the two apps, `flash.now` inside the redmine 147 / mastodon 29 flash cluster. Each is typed from
      # its Rails/Rack source contract, verified at v8.0.2 / rack v3.1.8.
      #
      # ## The predicates return a real `bool`, and a real `bool` does not fold
      #
      # Every method in this table is a zero-argument predicate whose body is a genuine boolean
      # expression — `request_method == POST` and its nine siblings in `Rack::Request::Helpers`,
      # `/XMLHttpRequest/i.match?(...)` for `xhr?` / `xml_http_request?`, `scheme == "https" || scheme ==
      # "wss"` for `ssl?`, two `LOCALHOST.match?` conjuncts for `local?`, and
      # `FORM_DATA_MEDIA_TYPES.include?(media_type)` for `form_data?`. None can return a non-boolean, so
      # `true | false` is the exact type rather than an approximation.
      #
      # `bool` is a UNION of the two constants, and that is what makes it FP-safe where a nominal would
      # not be: `flow.always-truthy-condition` fires when the flow proves the condition folds to ONE
      # constant, and a union of both never does. Measured on the shapes controllers actually write —
      # `return unless request.post?`, `if request.xhr? … else … end`, `mode = request.get? ? :a : :b`
      # followed by a live `mode == :a` guard, `request.post? && x`, `!request.get?` — the answer is zero
      # diagnostics, unchanged from the `Dynamic[top]` baseline. This is the opposite of the
      # `Parameters#[]` case (#578): there the candidate type was a non-nil *nominal* standing in for a
      # value that is nil at runtime, and the fold it licensed was wrong.
      #
      # The distinction the predicates turn on is *inertness*, not truthfulness, and it is narrower than
      # it looks: a two-constant union is inert because neither arm can be eliminated, while ANY nil-free
      # type — nominal or union of nominals — is not. `request.format` was withdrawn from this batch on
      # exactly that point (see below).
      REQUEST_PREDICATE_METHODS = %i[
        get? post? put? patch? delete? head? options? trace? link? unlink?
        xhr? xml_http_request? ssl? local? form_data?
      ].freeze

      dynamic_return receivers: [REQUEST_CONTEXT_READER_TYPES[:request]], methods: REQUEST_PREDICATE_METHODS do |call_node, _scope|
        next nil unless call_node.is_a?(Prism::CallNode)
        next nil unless call_node.arguments.nil?
        next nil unless call_node.block.nil?

        Rigor::Type::Combinator.union(
          Rigor::Type::Combinator.constant_of(true),
          Rigor::Type::Combinator.constant_of(false)
        )
      end

      # The FlashHash methods whose Rails body returns something this plugin can name on every path.
      #
      # - `now` is `@now ||= FlashNow.new(self)` — a memoised, never-nil `ActionDispatch::Flash::FlashNow`.
      #   It is the carrier behind `flash.now[:alert] = "…"`, the second-most-written flash idiom.
      # - `keep` and `discard` are `k ? self[k] : self`, so they are admissible ONLY in their
      #   zero-argument form, where the answer is `self` — a FlashHash. Given a key they return a leaf
      #   value or nil, which is the hazard below. The rule reads the arity syntactically, so the two
      #   spellings get different answers from the same table row.
      #
      # Both nominals are RBS-less, hence lenient, for the reason `REQUEST_CONTEXT_READER_TYPES`
      # documents.
      FLASH_CHAIN_TYPES = {
        now: "ActionDispatch::Flash::FlashNow",
        keep: REQUEST_CONTEXT_READER_TYPES[:flash],
        discard: REQUEST_CONTEXT_READER_TYPES[:flash]
      }.freeze

      # `keep` / `discard` answer `self` only when called with no key.
      FLASH_SELF_RETURNING_METHODS = %i[keep discard].freeze

      dynamic_return receivers: [REQUEST_CONTEXT_READER_TYPES[:flash]], methods: FLASH_CHAIN_TYPES.keys do |call_node, _scope|
        next nil unless call_node.is_a?(Prism::CallNode)
        next nil unless call_node.arguments.nil?
        next nil unless call_node.block.nil?

        class_name = FLASH_CHAIN_TYPES[call_node.name]
        next nil if class_name.nil?

        Rigor::Type::Combinator.nominal_of(class_name)
      end

      # ## What deliberately does NOT land here (issue #534, adjudicated 2026-09-02)
      #
      # **`request.format` was withdrawn from this batch and is filed as its own issue.** It was written
      # as `Mime::Type | Mime::NullType` — a union read straight off `formats.first ||
      # Mime::NullType.instance` — and review found the reasoning behind it wrong on the point that
      # matters. A two-class union of nominals is NOT flow-inert the way `true | false` is: neither Mime
      # arm is falsey, so the whole union is nil-free, and `mode = request.format ? :f : :n; return "a" if
      # mode == :n` draws `flow.always-truthy-condition`. That fold is truthful at runtime — `format`
      # really never returns nil — but truthfulness is not the bar this plugin has been holding, and the
      # fold was never adjudicated against the shapes controllers write.
      #
      # `Mime::NullType` is what makes it more than a paperwork problem. It is a nil-MASQUERADING object:
      # `mime_type.rb` (v8.0.2) gives it an explicit `def nil?; true; end`, so a nil-free union is the
      # wrong model of it, and mastodon's `account_controller_concern.rb` really does branch on
      # `request.format.nil?`. Measured today, `.nil?` on the union does not fold — but that is a
      # consequence of the arms being RBS-less, not of anything this table asserts, and nothing pinned it.
      # Typing `format` needs a nil-aware answer and its own adjudication, not a row here.
      #
      # **`FlashHash#[]=` and `Session#[]=` need no rule, and adding one could only do harm.** Two
      # independent measurements say so. First, Ruby's assignment-expression semantics make the value of
      # `flash[:notice] = msg` the RHS whatever `[]=` returns, and Rigor already models that: on a
      # controller fixture with no plugin rule at all, `flash[:notice] = "hi"` types `"hi"` and
      # `session[:user_id] = 1` types `1`. Second, `coverage --protection` scores a fixture of five such
      # writes at **6/6 (100%)** — the lens measures *receiver* concreteness, and `flash` / `session` are
      # already concrete nominals, so there is no coverage to win either. The corpus's "`FlashHash#[]=`
      # 127 / 29" is a *named-receiver pair* count (a dispatch whose method does not resolve), which no
      # return-type contribution can move. A rule here could only agree with the answer already given, or
      # contradict it.
      #
      # **`FlashHash#[]` and `Session#[]` stay untyped, and both candidate arms were run.** Both are leaf
      # reads — `@flashes[k.to_s]` and the session delegate's `[]` — returning whatever was stored, or
      # nil for a key that is not set, so this is `Parameters#[]` (#578) again and it measures the same:
      #
      # - **non-nil `String`**: `mode = flash[:notice] ? :flash : :plain` folds to `:flash`, and the live
      #   `mode == :plain` guard draws `flow.always-truthy-condition` — a diagnostic on a branch the
      #   program takes.
      # - **`String | nil`**: no folds, but `note = flash[:notice]; note.upcase` fires
      #   `call.possible-nil-receiver` at ERROR severity — the assigned-then-used shape controllers write
      #   constantly. (`uid.to_i` is silent because `NilClass` has `to_i`, which makes the noise
      #   unpredictable rather than absent.)
      #
      # One false positive each, on ordinary controller code, in exchange for a coverage number. Session
      # is if anything worse than Parameters: `session[:user_id]` is *the* nil-checked read in Rails, so
      # the fold lands on the guard that matters most. Reopening either needs the same rules-level change
      # #574 tracks, not a plugin table row. The specs pin both arms as executable controls.

      private

      # True when the current `self` is a controller — the enclosing class is one the discoverer
      # indexed, or its name follows the Rails `*Controller` convention (covering controllers outside
      # `controller_search_paths`, e.g. one shipped by an engine). Typing `params` is precision-additive,
      # so the name-convention fallback is FP-safe.
      def controller_scope?(scope)
        self_type = scope&.self_type
        return false unless self_type.respond_to?(:class_name)

        name = self_type.class_name
        return false if name.nil?

        index = producer_value(:controller_index)
        # `ControllerIndex#find` de-roots the query itself (#621) — no retry arm here.
        return true if index&.find(name)

        name.end_with?("Controller")
      end

      def controller_file?(path)
        @controller_search_paths.any? do |root|
          # The runner may pass `path` as either an absolute path (when `paths:` was configured
          # absolutely) or a relative one (when configured relatively). The `controller_search_paths`
          # knob is always project-root-relative. Match the configured root as a /-bracketed substring
          # so both shapes resolve.
          path.include?("/#{root}/") || path.start_with?("#{root}/") || path == root
        end
      end
    end

    Rigor::Plugin.register(Actionpack)
  end
end
