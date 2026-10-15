# frozen_string_literal: true

require_relative "../version"

module Rigor
  module Lens
    # `context.plugins` (docs/internal-spec/lens.md § Context): the plugins a run loaded, by manifest id.
    module Plugins
      BUNDLED_PLUGINS = File.expand_path("../../../plugins", __dir__).freeze

      module_function

      # `[{id, version}]` by manifest id (the id slot provenance uses). The version is Rigor's for a plugin bundled
      # with it, else the version of the gem whose files define the plugin class, else null. A plugin id is not a gem
      # name: the bundled `rbs-inline` plugin shares its id with the upstream gem.
      def loaded(environment)
        plugins = environment&.plugin_registry&.plugins || []
        rows = plugins.map { |plugin| { "id" => plugin.manifest.id.to_s, "version" => version(plugin) } }
        rows.uniq.sort_by { |plugin| plugin["id"] }
      rescue StandardError
        []
      end

      def version(plugin)
        file = Object.const_source_location(plugin.class.name)&.first
        return nil if file.nil?

        absolute = File.expand_path(file)
        return Rigor::VERSION if absolute.start_with?("#{BUNDLED_PLUGINS}/")

        spec = Gem.loaded_specs.each_value.find do |gem|
          absolute.start_with?("#{gem.full_gem_path}/") # rigor:disable undefined-method
        end
        spec&.version&.to_s
      rescue StandardError
        nil
      end
    end
  end
end
