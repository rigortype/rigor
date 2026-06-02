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

      # Whether the real `ActiveSupport::Inflector` can be loaded. A
      # consumer can gate inflection-dependent work on this to emit a
      # single clean load-error instead of letting the first inflection
      # raise. Memoised via {ensure_loaded!}.
      def available?
        ensure_loaded!
        true
      rescue Unavailable
        false
      end

      # Delegates an allow-listed method to the real
      # `ActiveSupport::Inflector`. Raises {Unavailable} (never
      # approximates) when the gem is absent.
      #
      # When `Ruby::Box` isolation is active (ADR-39 slice 5; opt-in via
      # `RUBY_BOX=1`), the call runs inside the shared box so ActiveSupport
      # never loads into Rigor's main space; `name` is a fixed allow-listed
      # method and `arg` is interpolated through `String#inspect` (a safe
      # Ruby literal), so the `eval` carries no free input. Otherwise the
      # library loads into the main space (slices 2/4 behaviour).
      def invoke(name, arg)
        raise ArgumentError, "method not allow-listed: #{name}" unless ALLOWED_METHODS.include?(name)

        return invoke_in_box(name, arg) if Box.enabled?

        ensure_loaded!
        ActiveSupport::Inflector.public_send(name, arg.to_s)
      end

      def invoke_in_box(name, arg)
        unless Box.require_feature("active_support/inflector")
          raise Unavailable,
                "ActiveSupport::Inflector could not be loaded into the Ruby::Box isolation space."
        end

        # The evaluated string is fully constrained: `name` is one of the
        # fixed {ALLOWED_METHODS} symbols and the argument is rendered via
        # `String#inspect` (a safe, round-tripping Ruby literal), so the
        # built expression is e.g. `ActiveSupport::Inflector.pluralize("person")`
        # — no free input ever reaches the box's `eval` (`Ruby::Box#eval`,
        # not `Kernel#eval`).
        expression = format("ActiveSupport::Inflector.%<method>s(%<arg>s)", method: name, arg: arg.to_s.inspect)
        Box.eval(expression)
      end

      # Loads `active_support/inflector` once. Core Rigor carries no
      # ActiveSupport dependency, so the require is lazy (the consuming
      # plugins bring the gem); a failure becomes {Unavailable}.
      def ensure_loaded!
        return if defined?(@loaded) && @loaded

        require "active_support/inflector"
        @loaded = true
      rescue LoadError => e
        raise Unavailable,
              "ActiveSupport::Inflector is required for inflection but could not be loaded " \
              "(#{e.message}). Add `activesupport` to the plugin's dependencies."
      end
    end
  end
end
