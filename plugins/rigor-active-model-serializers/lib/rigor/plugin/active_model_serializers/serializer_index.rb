# frozen_string_literal: true

module Rigor
  module Plugin
    class ActiveModelSerializers < Rigor::Plugin::Base
      # The serializer classes {SerializerDiscoverer} found under the configured search paths, keyed by
      # the class's fully-qualified name as the source spells it (`"REST::AccountSerializer"`).
      #
      # Each entry carries the declared superclass (so the discoverer can close the ancestry chain) and
      # the three name sets that let a candidate model be CHECKED rather than guessed:
      #
      # - `declared_names` — the names the serializer will read off the resource at render time: the
      #   symbols of `attributes` / `attribute` / `has_many` / `has_one` / `belongs_to`, minus the ones
      #   the serializer defines itself (AMS calls the serializer's own method when it has one, and only
      #   falls through to `object.<name>` when it does not).
      # - `object_reads` — every `object.<name>` the body writes, minus the methods every Object has.
      # - `own_method_names` — the serializer's own instance `def`s, which is both what subtracts from
      #   `declared_names` and how an explicit `def object` is detected.
      class SerializerIndex
        Entry = Data.define(:class_name, :superclass_name, :file_path, :declared_names, :object_reads,
                            :own_method_names) do
          # The declarations AMS will render by calling the name on the resource — unless an ancestor of
          # this serializer defines it, which only the engine's ancestor walk can say, so that half is
          # left to the caller.
          def unhandled_declarations = declared_names - own_method_names

          # Reads of the resource itself. Unlike a declaration, one of these is a read of the resource
          # whatever the serializer or its ancestors define.
          def resource_reads = object_reads

          def defines_object? = own_method_names.include?("object")
        end

        attr_reader :entries

        def initialize(entries)
          @entries = entries.freeze
          @by_name = entries.to_h { |entry| [entry.class_name, entry] }.freeze
          freeze
        end

        def find(class_name) = @by_name[derooted(class_name)]
        def known?(class_name) = @by_name.key?(derooted(class_name))
        def empty? = @entries.empty?
        def size = @entries.size
        def names = @by_name.keys

        private

        # A query may arrive rooted (`::REST::AccountSerializer`) while entries are keyed by the
        # de-rooted spelling, the same normalisation `rigor-activerecord`'s ModelIndex settled on in #583.
        def derooted(class_name) = class_name.to_s.delete_prefix("::")
      end
    end
  end
end
