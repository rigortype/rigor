# frozen_string_literal: true

module Rigor
  module Plugin
    # ADR-39 — the shared inflection helper for the Rails-family plugins
    # (`rigor-rails-routes`, `rigor-activerecord`, `rigor-actionpack`).
    #
    # Inflection (`posts` ↔ `post`, `BlogPost` → `blog_posts`) drives
    # route-helper and model-name resolution, so a divergence from Rails'
    # *actual* rules surfaces as a false positive on working code. Rather
    # than reimplement Rails' inflector (the hand-rolled `singularize` /
    # `pluralize` copies each plugin used to carry only approximated it —
    # missing `person`→`people`, `analysis`→`analyses`, `louse`→`lice`,
    # and every project-declared irregular), this helper invokes the
    # **real `ActiveSupport::Inflector`** when it is loadable.
    #
    # Per ADR-39 this is a permitted *target-library* invocation: the
    # methods called are a fixed, pure, allow-listed set
    # ({ALLOWED_METHODS}) on a trusted gem the consuming plugins declare
    # as a dependency, and every call is wrapped so a missing gem or an
    # unexpected result degrades to the built-in {Fallback} approximation
    # — never a crash. (`ActiveSupport::Inflector` is loaded, not the
    # analyzed application's code; project-specific inflection rules are
    # ingested by *statically parsing* `config/initializers/inflections.rb`
    # in a later slice, never by executing it.)
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
      # `pluralize` with the `::`→`_` flattening AR really uses — gaining
      # AS's pluralization accuracy without the namespaced-table FP.
      ALLOWED_METHODS = %i[underscore camelize singularize pluralize classify].freeze

      module_function

      # `BlogPost` → `blog_post`; `Admin::Foo` → `admin/foo`.
      def underscore(word)
        via_active_support(:underscore, word) { Fallback.underscore(word) }
      end

      # `blog_post` → `BlogPost`; `admin/foo` → `Admin::Foo`.
      def camelize(term)
        via_active_support(:camelize, term) { Fallback.camelize(term) }
      end

      # `posts` → `post`; `categories` → `category`.
      def singularize(word)
        via_active_support(:singularize, word) { Fallback.singularize(word) }
      end

      # `post` → `posts`; `category` → `categories`.
      def pluralize(word)
        via_active_support(:pluralize, word) { Fallback.pluralize(word) }
      end

      # `posts` → `Post`; `blog_posts` → `BlogPost`.
      def classify(table_name)
        via_active_support(:classify, table_name) { Fallback.classify(table_name) }
      end

      # `BlogPost` → `blog_posts`; `Admin::User` → `admin_users`.
      # Composed (not delegated) so the namespace flattens with `_` the
      # way ActiveRecord's table naming does — see {ALLOWED_METHODS}.
      def tableize(class_name)
        underscored = underscore(class_name.to_s.gsub("::", "/")).tr("/", "_")
        pluralize(underscored)
      end

      # Whether the real `ActiveSupport::Inflector` is available. Memoised:
      # the `require` is attempted once and the result cached for the
      # process. `false` means every method above uses {Fallback}.
      def active_support_available?
        return @active_support_available if defined?(@active_support_available)

        @active_support_available =
          begin
            require "active_support/inflector"
            true
          rescue LoadError, StandardError
            false
          end
      end

      # Invokes the allow-listed `ActiveSupport::Inflector` method when the
      # gem is present, falling back to the block (the built-in
      # approximation) when it is absent OR the call raises / returns a
      # non-String. The `ALLOWED_METHODS` guard keeps the call surface
      # fixed even though `name` is internal.
      def via_active_support(name, arg)
        return yield unless ALLOWED_METHODS.include?(name)
        return yield unless active_support_available?

        result = ActiveSupport::Inflector.public_send(name, arg.to_s)
        result.is_a?(String) ? result : yield
      rescue StandardError
        yield
      end

      # The built-in approximation used when `ActiveSupport::Inflector` is
      # not loadable. Ported verbatim from the algorithm `rigor-activerecord`
      # shipped (the richest of the former per-plugin copies) so the
      # gem-absent path is no worse than today; the real inflector is
      # strictly more accurate when present.
      module Fallback
        IRREGULAR_PLURALS = {
          "person" => "people",
          "child" => "children",
          "datum" => "data"
        }.freeze

        module_function

        def underscore(camel_case_word)
          word = camel_case_word.to_s.dup
          word.gsub!(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          word.gsub!(/([a-z\d])([A-Z])/, '\1_\2')
          word.tr!("-", "_")
          word.downcase!
          word
        end

        def classify(word)
          camelize(singularize(word.to_s))
        end

        def singularize(word)
          IRREGULAR_PLURALS.each { |singular, plural| return singular if word == plural }

          case word
          when /(.*[bcdfghjklmnpqrstvwxz])ies\z/
            "#{Regexp.last_match(1)}y"
          when /(.*[sxz]|.*[cs]h)es\z/
            Regexp.last_match(0)[0..-3]
          when /(.*)ves\z/
            "#{Regexp.last_match(1)}f"
          when /(.+)s\z/
            Regexp.last_match(1)
          else
            word
          end
        end

        def camelize(snake)
          snake.to_s.split("/").map do |segment|
            segment.split("_").map { |part| part.empty? ? part : part[0].upcase + part[1..] }.join
          end.join("::")
        end

        def pluralize(word)
          return IRREGULAR_PLURALS[word] if IRREGULAR_PLURALS.key?(word)

          case word
          when /(.*[bcdfghjklmnpqrstvwxz])y\z/
            "#{Regexp.last_match(1)}ies"
          when /(.*[sxz]|.*[cs]h)\z/
            "#{Regexp.last_match(0)}es"
          when /(.*)fe?\z/
            "#{Regexp.last_match(1)}ves"
          else
            "#{word}s"
          end
        end
      end
    end
  end
end
