# frozen_string_literal: true

module Rigor
  module Plugin
    class Actionpack < Rigor::Plugin::Base
      # Per-run frozen index of discovered controllers AND
      # concerns (modules) in `controller_search_paths`. Phase 2
      # (filter-chain validation) consults the index at every
      # call site to check that `before_action :name` references
      # a method that actually exists on the controller, its
      # parent (one level of inheritance), or any module the
      # controller or its ancestor chain transitively `include`s.
      #
      # Real-world example (Mastodon):
      #   AccountsController < ApplicationController
      #     include SignatureAuthentication      # local concern
      #   SignatureAuthentication < module
      #     include SignatureVerification         # local concern
      #   SignatureVerification < module
      #     def require_account_signature!        # ← the filter target
      #
      # The include chain spans three concern modules.
      # `effective_methods_for("AccountsController")` walks all
      # of them transitively to collect `require_account_signature!`.
      class ControllerIndex
        # `defined_methods` carries the discovered method names
        # (Symbols). `included_module_names` carries the constant
        # names passed to `include X` calls inside the
        # class / module body (Strings). `parent_class_name` is
        # the immediate superclass (nil for plain modules).
        # `enclosing_namespace` is the qualifier chain of the
        # declaration's *lexical* enclosing scope (e.g.
        # `["Admin"]` for an `Admin::Foo` declared via
        # `module Admin; class Foo; end; end`). Used by the
        # index's parent / module lookup to try lexically-scoped
        # constant resolution before falling through to the
        # top-level form — Ruby's constant lookup walks the
        # enclosing scope chain before `Object`.
        Entry = Data.define(:class_name, :defined_methods, :parent_class_name, :included_module_names,
                            :enclosing_namespace)

        attr_reader :entries

        def initialize(entries)
          @entries = entries.freeze
          freeze
        end

        # @return [Entry, nil]
        def find(class_name)
          @entries[class_name]
        end

        # Resolves the **effective** method set for a controller,
        # including methods contributed by every module the
        # controller / any ancestor transitively `include`s AND
        # methods inherited from the ancestor chain (unbounded
        # depth, cycle-safe via a visited set).
        #
        # Parent / module lookups are **lexically scoped** — a
        # bare `BaseController` reference inside `module Admin`
        # first tries `Admin::BaseController`, then falls
        # through to the top-level `BaseController`. Matches
        # Ruby's constant-resolution semantics. Without this an
        # `Admin::Foo < BaseController` declaration would
        # incorrectly walk the top-level `BaseController` even
        # when an `Admin::BaseController` exists.
        def effective_methods_for(class_name)
          seen_classes = {}
          seen_modules = {}
          methods = []
          current = class_name
          while current && !seen_classes[current]
            seen_classes[current] = true
            entry = @entries[current]
            break if entry.nil?

            methods.concat(entry.defined_methods)
            entry.included_module_names.each do |included|
              resolved_include = resolve_constant_lexically(included, entry.enclosing_namespace)
              collect_methods(resolved_include, seen_modules, methods)
            end
            next_parent = entry.parent_class_name
            # Same self-reference guard as `unresolved_include?`:
            # `class ActivityPub::ApplicationController <
            # ::ApplicationController` lexically resolves
            # `ApplicationController` to itself; fall back to
            # the unprefixed top-level name in that case.
            current = if next_parent
                        resolved = resolve_constant_lexically(next_parent, entry.enclosing_namespace)
                        resolved == current ? next_parent.sub(/\A::/, "") : resolved
                      end
          end
          methods.uniq.freeze
        end

        # @return [Boolean] true when the class has at least one
        #   include OR parent class we couldn't resolve in the
        #   index (typically a gem-shipped concern such as Devise's
        #   `Devise::Controllers::Helpers`, or a gem-shipped
        #   parent controller such as `Devise::ConfirmationsController`
        #   or `Doorkeeper::AuthorizedApplicationsController`).
        #   Phase 2 uses this to downgrade `unknown-filter-method`
        #   to silence — the unresolved module / parent may
        #   legitimately contribute the filter (either directly,
        #   or via its own ancestor chain which the static
        #   analyzer cannot follow), and there's no way to verify.
        def unresolved_include?(class_name)
          entry = @entries[class_name]
          return false if entry.nil?

          # Walk the full ancestor chain. `Admin::Foo <
          # BaseController < ApplicationController` should report
          # an unresolved include if ANY of the three references
          # a gem-shipped concern OR a gem-shipped parent class
          # we cannot index. The first iteration's `current_entry`
          # is always resolved (caller verified `known?`); a nil
          # `current_entry` on a subsequent iteration means the
          # AST-side `< Parent` reached a gem-shipped class
          # whose ancestor methods are invisible to us.
          seen_classes = {}
          current = class_name
          first = true
          while current && !seen_classes[current]
            seen_classes[current] = true
            current_entry = @entries[current]
            if current_entry.nil?
              return true unless first

              break
            end
            first = false

            current_entry.included_module_names.each do |included|
              resolved = resolve_constant_lexically(included, current_entry.enclosing_namespace)
              return true if resolved.nil? || !@entries.key?(resolved)
            end
            next_parent = current_entry.parent_class_name
            # Avoid lexically resolving to ourselves. `class
            # ActivityPub::ApplicationController < ::ApplicationController`
            # would otherwise resolve `ApplicationController` (in
            # the lexical scope `["ActivityPub"]`) to
            # `ActivityPub::ApplicationController` and short-
            # circuit the walk before reaching the top-level
            # parent. When the lexical match is the current
            # class itself, fall back to the unprefixed
            # top-level name.
            current = if next_parent
                        resolved = resolve_constant_lexically(next_parent, current_entry.enclosing_namespace)
                        resolved == current ? next_parent.sub(/\A::/, "") : resolved
                      end
          end
          false
        end

        def empty?
          @entries.empty?
        end

        def known?(class_name)
          @entries.key?(class_name)
        end

        def class_names
          @entries.keys
        end

        private

        def collect_methods(name, seen, into)
          return if name.nil?

          entry = @entries[name]
          return if entry.nil? || seen[name]

          seen[name] = true
          into.concat(entry.defined_methods)
          entry.included_module_names.each do |included|
            resolved = resolve_constant_lexically(included, entry.enclosing_namespace)
            collect_methods(resolved, seen, into)
          end
        end

        # Ruby's constant-lookup walk: a bare constant name
        # inside `module Admin` first tries `Admin::Const`,
        # then walks outward, and finally falls through to
        # top-level `Const`. We approximate that by trying
        # the candidate `enclosing + name` chains from
        # deepest to shallowest, and returning the first
        # candidate that has an entry in the index. When
        # nothing resolves, return the original name
        # unchanged — the caller treats unresolved entries as
        # "gem-shipped concerns we cannot see" (the
        # `unresolved_include?` predicate).
        #
        # `name` may already be qualified (`Foo::Bar`); we
        # only try lexical prefixing when the unqualified
        # first segment doesn't match a top-level entry.
        def resolve_constant_lexically(name, enclosing)
          return nil if name.nil?

          # A leading `::` denotes the top-level constant
          # explicitly (`< ::ApplicationController`). Strip it
          # for index lookup — the discoverer registers entries
          # under their unprefixed name. Without this strip a
          # `class ActivityPub::ApplicationController <
          # ::ApplicationController` parent never resolved.
          name = name.sub(/\A::/, "")

          # Constant already absolute or no enclosing scope.
          return name if enclosing.nil? || enclosing.empty?

          # Try the deepest enclosing scope first, walking
          # outward. `enclosing = ["A", "B"]` produces
          # candidates `["A::B::name", "A::name", "name"]`.
          enclosing.length.downto(0).each do |depth|
            prefix = enclosing[0, depth]
            candidate = prefix.empty? ? name : "#{prefix.join('::')}::#{name}"
            return candidate if @entries.key?(candidate)
          end
          name
        end
      end
    end
  end
end
