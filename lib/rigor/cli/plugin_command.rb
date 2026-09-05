# frozen_string_literal: true

require_relative "command"

module Rigor
  class CLI
    # `rigor plugin` (singular) — discover and read the plugin source bundled with the `rigortype` gem.
    #
    # Rigor ships ~30 production plugins under `plugins/` and a set of tutorial plugins under `examples/`. When Rigor is
    # installed via `mise` / `gem install` the gem checkout is on disk, so a plugin author (or an AI coding agent
    # following the `rigor-plugin-author` skill) can read a real, working plugin as a worked example — instead of
    # guessing the `Rigor::Plugin::Base` surface from prose. This command outputs the absolute paths so they can be
    # found and read regardless of where the gem landed.
    #
    # It is deliberately distinct from `rigor plugins` (plural), which reports the activation status of the plugins
    # configured in *your* `.rigor.yml`. This command (singular) browses the plugins bundled in the *toolchain*.
    # Mnemonic: "plugins" = my config; "plugin" = the catalogue I can learn from.
    #
    # Subcommands:
    #
    # - `rigor plugin list`          — every bundled plugin + example,
    #                                  name + absolute directory path.
    # - `rigor plugin path <name>`   — one-line absolute path to the
    #                                  plugin's directory (Read-tool input).
    # - `rigor plugin print <name>`  — a header (dir / lib / sig / README
    #                                  paths) followed by the plugin's main
    #                                  `lib/<name>.rb` source body.
    # - `rigor plugin root`          — the rigortype gem root and its key
    #                                  subdirectories (lib/, plugins/,
    #                                  examples/, skills/, sig/), so an
    #                                  author can read the public plugin
    #                                  API (`lib/rigor/plugin.rb`) directly.
    #
    # `rigor plugin` with no subcommand is an alias for `list`.
    #
    # **Docker / cross-filesystem note.** Every path printed is resolved at runtime from this file's location, so it is
    # correct *on the filesystem where `rigor` runs*. If you run `rigor` inside a container but read files from the host
    # (or vice versa), the paths will not resolve — read them from the same environment that ran the command (`rigor
    # plugin print` inlines the body for exactly this case: it works with no file-reading tool at all).
    class PluginCommand < Command
      USAGE = <<~USAGE
        Usage: rigor plugin <subcommand> [args]

        Browse the plugins bundled in the rigortype toolchain (worked
        examples for authoring your own). For the activation status of
        the plugins in your .rigor.yml, use `rigor plugins` (plural).

        Subcommands:
          list                  List bundled + example plugins (default)
          path  <name>          Print the absolute directory path of <name>
          print <name>          Print <name>'s main lib source, with a header
          root                  Print the gem root + key subdirectories

        Examples:
          rigor plugin list
          rigor plugin path  rigor-activerecord
          rigor plugin print rigor-activesupport-core-ext
          rigor plugin root
      USAGE

      # The bundled plugins/examples/source live at `<gem_root>/...`. From `lib/rigor/cli/plugin_command.rb` the gem
      # root is three directories up (matching SkillCommand::SKILLS_ROOT).
      GEM_ROOT     = File.expand_path("../../..", __dir__)
      PLUGINS_ROOT = File.join(GEM_ROOT, "plugins")
      EXAMPLES_ROOT = File.join(GEM_ROOT, "examples")

      # @rbs return: Integer -- CLI exit status.
      def run
        subcommand = @argv.shift || "list"

        case subcommand
        when "list" then run_list
        when "path" then run_path
        when "print" then run_print
        when "root" then run_root
        when "-h", "--help", "help"
          @out.puts(USAGE)
          0
        else
          @err.puts("Unknown subcommand: #{subcommand}")
          @err.puts(USAGE)
          Rigor::CLI::EXIT_USAGE
        end
      end

      private

      def run_list
        plugins = discover(PLUGINS_ROOT)
        examples = discover(EXAMPLES_ROOT)
        if plugins.empty? && examples.empty?
          @err.puts("No bundled plugins found under #{PLUGINS_ROOT}")
          return 1
        end

        width = (plugins + examples).map { |p| p.fetch(:name).length }.max
        emit_group("Production plugins", PLUGINS_ROOT, plugins, width)
        emit_group("Example plugins (tutorials)", EXAMPLES_ROOT, examples, width)
        @out.puts
        @out.puts("Engine source root: #{GEM_ROOT}")
        @out.puts("  public plugin API: #{File.join(GEM_ROOT, 'lib/rigor/plugin.rb')}")
        @out.puts(docker_note)
        0
      end

      def emit_group(label, root, entries, width)
        return if entries.empty?

        @out.puts("#{label} — under #{root}:")
        entries.each do |entry|
          @out.puts(format("  %-#{width}s  %s", entry.fetch(:name), entry.fetch(:path)))
        end
      end

      def run_path
        name = @argv.shift
        return usage_error("`path` requires a plugin name") if name.nil?

        plugin = find(name)
        return name_error(name) if plugin.nil?

        @out.puts(plugin.fetch(:path))
        0
      end

      def run_print
        name = @argv.shift
        return usage_error("`print` requires a plugin name") if name.nil?

        plugin = find(name)
        return name_error(name) if plugin.nil?

        @out.puts(render_print_header(plugin))
        @out.puts
        entry = main_source_file(plugin)
        if entry
          @out.write(File.read(entry))
        else
          @out.puts("# (no lib/#{plugin.fetch(:name)}.rb entry file found; browse the directory above)")
        end
        0
      end

      def run_root
        @out.puts("rigortype gem root: #{GEM_ROOT}")
        {
          "lib (engine source)" => File.join(GEM_ROOT, "lib"),
          "lib/rigor/plugin.rb (public plugin API)" => File.join(GEM_ROOT, "lib/rigor/plugin.rb"),
          "plugins (production plugins)" => PLUGINS_ROOT,
          "examples (tutorial plugins)" => EXAMPLES_ROOT,
          "skills (Agent Skills)" => File.join(GEM_ROOT, "skills"),
          "sig (bundled RBS)" => File.join(GEM_ROOT, "sig")
        }.each do |label, path|
          marker = File.exist?(path) ? "" : "  (missing)"
          @out.puts(format("  %<label>-42s %<path>s%<marker>s", label: label, path: path, marker: marker))
        end
        @out.puts(docker_note)
        0
      end

      # The header that precedes the plugin body when an author runs `rigor plugin print <name>`. `# `-prefixed so the
      # combined output stays readable; the Ruby body below it is unchanged.
      def render_print_header(plugin)
        dir = plugin.fetch(:path)
        sig = File.join(dir, "sig")
        readme = File.join(dir, "README.md")
        <<~HEADER.chomp
          # Rigor plugin: #{plugin.fetch(:name)}  (#{plugin.fetch(:kind)})
          # Directory: #{dir}
          # Lib:       #{File.join(dir, 'lib')}
          # Sig:       #{File.directory?(sig) ? sig : '(none)'}
          # README:    #{File.file?(readme) ? readme : '(none)'}
          #
          # A real, working plugin shipped with rigortype #{Rigor::VERSION}.
          # The main source body is below; read the other files from the
          # paths above. To suppress `call.undefined-method` for methods a
          # DSL generates, study how an RBS-bundle plugin ships `sig/` (see
          # `rigor plugin print rigor-activesupport-core-ext`).
        HEADER
      end

      def discover(root)
        return [] unless File.directory?(root)

        kind = root == EXAMPLES_ROOT ? "example" : "production"
        Dir.children(root).sort.filter_map do |name|
          dir = File.join(root, name)
          next unless File.directory?(dir)

          { name: name, path: dir, kind: kind }
        end
      end

      # Match the directory name with or without the conventional `rigor-` prefix, so both `rigor-activerecord` and
      # `activerecord` resolve.
      def find(name)
        all = discover(PLUGINS_ROOT) + discover(EXAMPLES_ROOT)
        all.find { |p| p.fetch(:name) == name } ||
          all.find { |p| p.fetch(:name).delete_prefix("rigor-") == name.delete_prefix("rigor-") }
      end

      def main_source_file(plugin)
        dir = plugin.fetch(:path)
        candidate = File.join(dir, "lib", "#{plugin.fetch(:name)}.rb")
        return candidate if File.file?(candidate)

        Dir.glob(File.join(dir, "lib", "*.rb")).min
      end

      def docker_note
        "\nNote: paths are local to where `rigor` runs. If you run rigor in a " \
          "container,\nread these files from the same filesystem (use " \
          "`rigor plugin print` to inline a body)."
      end

      def name_error(name)
        @err.puts("Unknown plugin: #{name}")
        @err.puts("Run `rigor plugin list` to see the bundled plugins.")
        1
      end

      def usage_error(message)
        @err.puts(message)
        @err.puts(USAGE)
        Rigor::CLI::EXIT_USAGE
      end
    end
  end
end
