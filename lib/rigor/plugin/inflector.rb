# frozen_string_literal: true

module Rigor
  module Plugin
    # ADR-39 — the shared inflection helper for the Rails-family plugins
    # (`rigor-rails-routes`, `rigor-activerecord`, `rigor-actionpack`).
    #
    # Inflection (`posts` ↔ `post`, `BlogPost` → `blog_posts`) drives
    # route-helper and model-name resolution, so an inflection that
    # diverges from Rails' *actual* rules produces a wrong helper / model
    # name and therefore a **false positive on working code** (a bogus
    # `unknown-helper` / `unknown-permit-key`). Rigor therefore inflects
    # **only** with the real `ActiveSupport::Inflector` — the authority
    # Rails itself uses — and carries **no built-in approximation**: an
    # approximation would be exactly the source of wrong facts the
    # false-positive discipline forbids.
    #
    # Per ADR-39 this is a permitted *target-library* invocation: the
    # methods called are a fixed, pure, allow-listed set
    # ({ALLOWED_METHODS}) on a trusted gem the consuming plugins declare
    # as a dependency. (`ActiveSupport::Inflector` is loaded, not the
    # analyzed application's code; project-specific inflection rules are
    # ingested by *statically parsing* `config/initializers/inflections.rb`
    # in a later slice, never by executing it.)
    #
    # **Absence is silence, never a guess.** When `ActiveSupport::Inflector`
    # cannot be loaded (a misconfiguration — the consuming plugins declare
    # it as a dependency, so it is present in practice), the inflection
    # methods raise {Unavailable} rather than approximate. That raise
    # propagates to the caller's per-plugin rescue boundary, so the
    # inflection-dependent check degrades to **no diagnostics** — reduced
    # coverage, never a wrong fact. A consumer that wants to fail cleanly
    # up front can gate on {available?} and emit a single load-error.
    module Inflector
      # The pure, side-effect-free `ActiveSupport::Inflector` methods this
      # helper is permitted to call (ADR-39 § "safety harness"). The set
      # is fixed and greppable — never a dynamic `public_send`.
      #
      # `tableize` is deliberately NOT delegated: `ActiveSupport::Inflector.
      # tableize("Admin::User")` returns `"admin/users"`, but ActiveRecord's
      # *actual* table name flattens the namespace to `"admin_users"` (the
      # table-name computation does more than the pure `tableize` string
      # method). So {.tableize} composes the AS-backed `underscore` /
      # `pluralize` with the `::`→`_` flattening AR really uses.
      ALLOWED_METHODS = %i[underscore camelize singularize pluralize classify].freeze

      # The target library + the constant the allow-listed methods are
      # called on. Passed to {Isolation} so the call runs under the
      # configured isolation strategy (none / ruby_box / process).
      FEATURE = "active_support/inflector"
      RECEIVER = "ActiveSupport::Inflector"

      # Raised when `ActiveSupport::Inflector` is required for an
      # inflection but cannot be loaded. Caught by the per-plugin isolation
      # boundary, so it surfaces as "this plugin produced no diagnostics"
      # rather than a wrong inflection.
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

      # `BlogPost` → `blog_posts`; `Admin::User` → `admin_users`.
      # Composed (not delegated) so the namespace flattens with `_` the
      # way ActiveRecord's table naming does — see {ALLOWED_METHODS}.
      def tableize(class_name)
        underscored = underscore(class_name.to_s.gsub("::", "/")).tr("/", "_")
        pluralize(underscored)
      end

      # Whether inflection is available under the configured isolation
      # strategy. A consumer can gate inflection-dependent work on this to
      # emit a single clean load-error instead of letting the first
      # inflection raise. Probes with a trivial pluralization.
      def available?
        invoke(:pluralize, "rigor_inflector_probe")
        true
      rescue Unavailable
        false
      end

      # Delegates an allow-listed method to the real
      # `ActiveSupport::Inflector` through the configured isolation
      # strategy ({Isolation}: none / ruby_box / process). Raises
      # {Unavailable} (never approximates) when the library cannot be
      # reached in that strategy — the caller's per-plugin rescue turns
      # that into silence, never a wrong inflection.
      def invoke(name, arg)
        raise ArgumentError, "method not allow-listed: #{name}" unless ALLOWED_METHODS.include?(name)

        Isolation.call(feature: FEATURE, receiver: RECEIVER, method: name, args: [arg.to_s])
      rescue Isolation::Unavailable => e
        raise Unavailable, e.message
      end
    end
  end
end
