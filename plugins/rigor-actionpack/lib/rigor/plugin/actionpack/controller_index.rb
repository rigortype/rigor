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
        Entry = Data.define(:class_name, :defined_methods, :parent_class_name, :included_module_names)

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
        # including methods inherited from its parent class
        # (one level) and methods contributed by every module the
        # controller / its parent transitively `include`s
        # (unbounded depth, cycle-safe via a visited set).
        def effective_methods_for(class_name)
          seen = {}
          methods = []
          collect_methods(class_name, seen, methods)
          if (parent = @entries[class_name]&.parent_class_name)
            collect_methods(parent, seen, methods)
          end
          methods.uniq.freeze
        end

        # @return [Boolean] true when the class has at least one
        #   include we couldn't resolve in the index (typically
        #   a gem-shipped concern such as Devise's
        #   `Devise::Controllers::Helpers`). Phase 2 uses this
        #   to downgrade `unknown-filter-method` to silence —
        #   the unresolved module may legitimately contribute
        #   the filter, and there's no way for the static
        #   analyzer to verify.
        def has_unresolved_include?(class_name)
          entry = @entries[class_name]
          return false if entry.nil?

          chain = [class_name]
          chain << entry.parent_class_name if entry.parent_class_name
          chain.any? do |c|
            walk_includes(c, {}) { |m| return true unless @entries.key?(m) }
            false
          end
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
          entry = @entries[name]
          return if entry.nil? || seen[name]

          seen[name] = true
          into.concat(entry.defined_methods)
          entry.included_module_names.each do |included|
            collect_methods(included, seen, into)
          end
        end

        # Yields each transitively-included module name (whether
        # we have an entry for it or not). Returns nil; callers
        # use it for visit-and-classify, not to collect.
        def walk_includes(name, seen, &block)
          return if seen[name]

          seen[name] = true
          entry = @entries[name]
          return unless entry

          entry.included_module_names.each do |included|
            yield included
            walk_includes(included, seen, &block)
          end
        end
      end
    end
  end
end
