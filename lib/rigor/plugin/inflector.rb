# frozen_string_literal: true

module Rigor
  module Plugin
    # ADR-39 — the shared inflection helper for the Rails-family plugins (`rigor-rails-routes`,
    # `rigor-activerecord`, `rigor-actionpack`).
    #
    # Inflection (`posts` ↔ `post`, `BlogPost` → `blog_posts`) drives route-helper and model-name resolution, so
    # an inflection that diverges from Rails' *actual* rules produces a wrong helper / model name and therefore
    # a **false positive on working code** (a bogus `unknown-helper` / `unknown-permit-key`). Rigor therefore
    # inflects **only** with the real `ActiveSupport::Inflector` — the authority Rails itself uses — and
    # carries **no built-in approximation**: an approximation would be exactly the source of wrong facts the
    # false-positive discipline forbids.
    #
    # Per ADR-39 this is a permitted *target-library* invocation: the methods called are a fixed, pure,
    # allow-listed set ({ALLOWED_METHODS}) on a trusted gem the consuming plugins declare as a dependency.
    # (`ActiveSupport::Inflector` is loaded, not the analyzed application's code; project-specific inflection
    # rules are ingested by *statically parsing* `config/initializers/inflections.rb` in a later slice, never
    # by executing it.)
    #
    # **Absence is silence, never a guess.** ActiveSupport is resolved from Rigor's host gem environment
    # first, then from the analyzed project's own bundler install tree ({Isolation.target_bundle_root},
    # ADR-90) — a Rails project always carries its locked activesupport on disk, and that copy is the
    # higher-fidelity source of inflection rules anyway. When neither resolves (a standalone install
    # analyzing a project whose bundle is not installed), the inflection methods raise {Unavailable}
    # rather than approximate. That raise propagates to the caller's
    # per-plugin rescue boundary, so the inflection-dependent check degrades to **no diagnostics** — reduced
    # coverage, never a wrong fact. A consumer that wants to fail cleanly up front can gate on {available?}
    # and emit a single load-error.
    module Inflector
      # The pure, side-effect-free `ActiveSupport::Inflector` methods this helper is permitted to call (ADR-39
      # § "safety harness"). The set is fixed and greppable — never a dynamic `public_send`.
      #
      # `tableize` is deliberately NOT delegated: `ActiveSupport::Inflector.tableize("Admin::User")` returns
      # `"admin/users"`, a slash-separated path, never a valid SQL table name. {.tableize} composes the
      # AS-backed `underscore` / `pluralize` with a `::`→`_` flatten instead, so a caller already holding a
      # BARE (non-namespaced) name gets a plain identifier back rather than a path.
      #
      # This is NOT ActiveRecord's actual table-name algorithm for a namespaced model — Rails demodulizes
      # (drops the enclosing module entirely) rather than flattening it into the name, and prepends /
      # appends `table_name_prefix` / `table_name_suffix` only when the enclosing module declares one.
      # `rigor-activerecord`'s `ModelIndex.inflected_table_name` does that demodulize-then-decorate
      # sequence and calls here only with the already-demodulized (so already namespace-free) local class
      # name — the `::`→`_` flatten below never actually fires from that caller (#623 fixed a version of
      # this method that WAS called with the full namespaced path).
      ALLOWED_METHODS = %i[underscore camelize singularize pluralize classify].freeze

      # The target library + the constant the allow-listed methods are called on. Passed to {Isolation} so the
      # call runs under the configured isolation strategy (none / ruby_box / process).
      FEATURE = "active_support/inflector"
      RECEIVER = "ActiveSupport::Inflector"

      # The bundled plugins whose checks consume this helper (each README documents the dependency). Used
      # by `rigor plugins` (ADR-90) to probe {available?} at activation time — so a standalone install
      # where inflection silently degrades reports the degradation instead of an unqualified `[OK]`. When
      # a new plugin adopts the helper, add its manifest id here.
      CONSUMER_PLUGIN_IDS = %w[actionmailer actionpack activerecord factorybot rails-routes].freeze

      # Raised when `ActiveSupport::Inflector` is required for an inflection but cannot be loaded. Caught by
      # the per-plugin isolation boundary, so it surfaces as "this plugin produced no diagnostics" rather than
      # a wrong inflection.
      class Unavailable < StandardError
      end

      module_function

      # `BlogPost` → `blog_post`; `Admin::Foo` → `admin/foo`.
      def underscore(word)
        invoke(:underscore, word)
      end

      # `blog_post` → `BlogPost`; `admin/foo` → `Admin::Foo`.
      def camelize(term)
        invoke(:camelize, term)
      end

      # `posts` → `post`; `categories` → `category`.
      def singularize(word)
        invoke(:singularize, word)
      end

      # `post` → `posts`; `category` → `categories`.
      def pluralize(word)
        invoke(:pluralize, word)
      end

      # `posts` → `Post`; `blog_posts` → `BlogPost`.
      def classify(table_name)
        invoke(:classify, table_name)
      end

      # `BlogPost` → `blog_posts`; `Admin::User` → `admin_users`. Composed (not delegated) so the namespace
      # flattens with `_` the way ActiveRecord's table naming does — see {ALLOWED_METHODS}.
      def tableize(class_name)
        underscored = underscore(class_name.to_s.gsub("::", "/")).tr("/", "_")
        pluralize(underscored)
      end

      # Whether inflection is available under the configured isolation strategy. A consumer can gate
      # inflection-dependent work on this to emit a single clean load-error instead of letting the first
      # inflection raise. Probes with a trivial pluralization.
      def available?
        invoke(:pluralize, "rigor_inflector_probe")
        true
      rescue Unavailable
        false
      end

      # Delegates an allow-listed method to the real `ActiveSupport::Inflector` through the configured
      # isolation strategy ({Isolation}: none / ruby_box / process). Raises {Unavailable} (never approximates)
      # when the library cannot be reached in that strategy — the caller's per-plugin rescue turns that into
      # silence, never a wrong inflection.
      def invoke(name, arg)
        raise ArgumentError, "method not allow-listed: #{name}" unless ALLOWED_METHODS.include?(name)

        Isolation.call(feature: FEATURE, receiver: RECEIVER, method: name, args: [arg.to_s])
      rescue Isolation::Unavailable => e
        raise Unavailable, e.message
      end
    end
  end
end
