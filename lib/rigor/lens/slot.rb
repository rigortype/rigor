# frozen_string_literal: true

module Rigor
  module Lens
    # Tagged type slots and RBS-buffer provenance (docs/internal-spec/lens.md § Slots).
    module Slot
      module_function

      def typed(type, provenance, path: nil, from_site: nil)
        { "state" => "typed", "type" => type, "provenance" => provenance, "path" => path, "from_site" => from_site }
      end

      def dynamic(provenance, cause, path: nil, from_site: nil)
        { "state" => "dynamic", "type" => "untyped", "provenance" => provenance, "path" => path,
          "from_site" => from_site, "cause" => cause&.to_s }
      end

      def unavailable(reason)
        { "state" => "unavailable", "reason" => reason }
      end

      def unavailable?(slot)
        slot.is_a?(Hash) && slot["state"] == "unavailable"
      end

      # A slot for an RBS type string read from a contract. `untyped` is a dynamic slot whose cause is the
      # authored contract.
      def from_rbs(type, provenance, path)
        return dynamic(provenance, :explicit_untyped, path: path) if type == "untyped"

        typed(type, provenance, path: path)
      end

      # The RBS type a slot puts in an overload's `rbs` string: an unavailable slot reads `untyped`.
      def rbs_spelling(slot)
        slot["state"] == "typed" ? slot["type"] : "untyped"
      end
    end

    # Maps an RBS member's buffer name to a provenance (§ Slots).
    class Provenance
      CACHED_BUFFER = "<cached>"

      # @param root — the project root (absolute)
      # @param signature_roots — the project signature roots (absolute)
      # @param plugin_roots — `{absolute signature directory => plugin id}` of the loaded plugins
      def initialize(root:, signature_roots:, plugin_roots:)
        @root = root
        @signature_roots = signature_roots
        @plugin_roots = plugin_roots
      end

      # [provenance, path] for a buffer name, or nil when the buffer cannot be classified.
      def classify(buffer_name)
        name = buffer_name.to_s
        return ["inline", nil] if name.start_with?("virtual:rbs-inline:")
        return ["plugin:#{name.split(':', 3)[1]}", nil] if name.start_with?("virtual:")
        return nil if name.empty? || name == CACHED_BUFFER

        absolute = File.expand_path(name, @root)
        plugin = @plugin_roots.find { |root, _| under?(absolute, [root]) }
        return ["plugin:#{plugin.last}", nil] if plugin
        return ["sig", relative(absolute)] if under?(absolute, @signature_roots)

        ["library", nil]
      end

      def relative(absolute)
        Pathname(absolute).relative_path_from(Pathname(@root)).to_s
      end

      private

      def under?(absolute, roots)
        roots.any? { |root| absolute == root || absolute.start_with?("#{root}/") }
      end
    end
  end
end
