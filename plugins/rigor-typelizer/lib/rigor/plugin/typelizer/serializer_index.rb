# frozen_string_literal: true

module Rigor
  module Plugin
    class Typelizer < Rigor::Plugin::Base
      # The project's classes (every file of the project's `paths:` and the typelizer `dirs`), as the {SerializerCollector} found them. A frozen value
      # object the `:serializer_index` producer caches.
      #
      # {#roots} answers the one question, conservatively — a wrong "no" costs a missing root, a wrong "yes"
      # hides a dead class.
      class SerializerIndex
        # A class the project declares. `superclass` is the constant as written (`nil` when absent) and
        # `nesting` the `Module.nesting` chain (innermost first) its header was written under, which is where
        # Ruby resolves that constant. `dsl` is true when its body includes or extends `Typelizer::DSL`; `in_dirs` when a file under the
        # typelizer `dirs` declares it (only such a class is published as a root).
        ClassEntry = Data.define(:name, :superclass, :nesting, :dsl, :in_dirs)

        def initialize(classes:)
          @classes = classes.to_h { |entry| [entry.name, entry] }.freeze
          freeze
        end

        def empty?
          @classes.empty?
        end

        # Every class typelizer generates an interface for: a class that registered itself through the DSL, and
        # each subclass of one (`Typelizer.target_serializers` takes `descendants`).
        def roots
          @classes.keys.select { |name| @classes[name].in_dirs && typelized?(name, {}) }.sort
        end

        private

        def typelized?(name, seen)
          entry = @classes[name]
          return false if entry.nil? || seen[name]

          seen[name] = true
          return true if entry.dsl

          parent = superclass_of(entry)
          !parent.nil? && typelized?(parent, seen)
        end

        # Resolves the superclass as written the way Ruby does: against the `Module.nesting` chain of the header,
        # innermost first, then the top level. A compact header (`class Admin::UserSerializer < Base`) does not
        # put `Admin` on the chain, so `Base` is not looked up under it. The first match wins, so a class that
        # shadows the DSL base (`Admin::Base` with no DSL) ends the walk there.
        #
        # Ruby also searches the ancestors of the innermost cref before the top level. That is not modelled, so a
        # name that is not found on the lexical chain is declined (nil: not typelized) when the innermost scope
        # is a class with a superclass, since the constant might live on that superclass.
        def superclass_of(entry)
          written = entry.superclass
          return nil if written.nil?

          if written.start_with?("::")
            rooted = written.delete_prefix("::")
            return @classes.key?(rooted) ? rooted : nil
          end

          lexical = entry.nesting.map { |scope| "#{scope}::#{written}" }.find { |name| @classes.key?(name) }
          return lexical if lexical
          return nil if cref_has_ancestors?(entry.nesting.first)

          @classes.key?(written) ? written : nil
        end

        def cref_has_ancestors?(scope)
          !scope.nil? && !@classes[scope]&.superclass.nil?
        end
      end
    end
  end
end
