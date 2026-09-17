# frozen_string_literal: true

module Rigor
  module Plugin
    class ActiveModelSerializers < Rigor::Plugin::Base
      # The serializer classes {SerializerDiscoverer} found under the configured search paths, keyed by
      # the class's fully-qualified name as the source spells it (`"REST::AccountSerializer"`).
      #
      # The index answers one question — "is `self` a serializer here?" — and carries the declared
      # superclass only so the discoverer can close the chain. Nothing downstream reads a member list,
      # because the plugin asserts nothing about a serializer's method surface.
      class SerializerIndex
        Entry = Data.define(:class_name, :superclass_name, :file_path)

        attr_reader :entries

        def initialize(entries)
          @entries = entries.freeze
          @by_name = entries.to_h { |entry| [entry.class_name, entry] }.freeze
          freeze
        end

        def find(class_name) = @by_name[strip_leading_namespace(class_name)]
        def known?(class_name) = @by_name.key?(strip_leading_namespace(class_name))
        def empty? = @entries.empty?
        def size = @entries.size
        def names = @by_name.keys

        private

        # A query may arrive rooted (`::REST::AccountSerializer`) while entries are keyed by the
        # de-rooted spelling, the same normalisation `rigor-activerecord`'s ModelIndex settled on in #583.
        def strip_leading_namespace(class_name)
          class_name.to_s.delete_prefix("::")
        end
      end
    end
  end
end
