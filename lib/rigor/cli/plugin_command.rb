# frozen_string_literal: true

require "optparse"

require_relative "command"
require_relative "../rooted_glob"

module Rigor
  class CLI
    # `rigor plugin` (singular) — discover and read the plugin source bundled with the `rigortype` gem.
    #
    # Rigor ships production plugins under `plugins/` and tutorial plugins under `examples/`. When Rigor is
    # installed via `mise` / `gem install` the gem checkout is on disk, so a plugin author (or an AI coding agent
    # following the `rigor-plugin-author` skill) can read a real, working plugin as a worked example — instead of
    # guessing the `Rigor::Plugin::Base` surface from prose. This command outputs the absolute paths so they can be
    # found and read regardless of where the gem landed.
    #
    # It is deliberately distinct from `rigor plugins` (plural), which reports the activation status of the plugins
    # configured in *your* `.rigor.yml`. This command (singular) browses the plugins bundled in the *toolchain*.
    # Mnemonic: "plugins" = my config; "plugin" = the catalogue I can learn from.
    #
    # Grammar (mirrors `rigor docs` and `rigor skill`, ADR-126 WD4): the positional slot is always a plugin *name*;
    # alternative outputs are flags, so a plugin can never be shadowed by a verb.
    #
    # - `rigor plugin`               — every bundled plugin + example, name + absolute directory path (the default).
    # - `rigor plugin <name>`        — a header (dir / lib / sig / README paths) followed by the plugin's main
    #                                  `lib/<name>.rb` source body.
    # - `rigor plugin --path <name>` — one-line absolute path to the plugin's directory (Read-tool input).
    # - `rigor plugin --list`        — the same listing as no argument.
    # - `rigor plugin --root`        — the rigortype gem root and its key subdirectories (lib/, plugins/, examples/,
    #                                  skills/, sig/), so an author can read the public plugin API
    #                                  (`lib/rigor/plugin.rb`) directly.
    #
    # The verbs `list`, `path <name>`, `print <name>` and `root` are the pre-ADR-126 spelling. They still work for one
    # minor, print the same stdout and return the same status, and add one deprecation notice on stderr naming the
    # replacement.
    #
    # **Docker / cross-filesystem note.** Every path printed is resolved at runtime from this file's location, so it is
    # correct *on the filesystem where `rigor` runs*. If you run `rigor` inside a container but read files from the host
    # (or vice versa), the paths will not resolve — read them from the same environment that ran the command (`rigor
    # plugin <name>` inlines the body for exactly this case: it works with no file-reading tool at all).
    class PluginCommand < Command
      USAGE = <<~USAGE
        Usage: rigor plugin [<name>] [--path <name>] [--list] [--root]

        Browse the plugins bundled in the rigortype toolchain (worked
        examples for authoring your own). For the activation status of
        the plugins in your .rigor.yml, use `rigor plugins` (plural).

          rigor plugin                List bundled + example plugins
          rigor plugin <name>         Print <name>'s main lib source, with a header
          rigor plugin --path <name>  Print the absolute directory path of <name>
          rigor plugin --list         List bundled + example plugins
          rigor plugin --root         Print the gem root + key subdirectories

        Examples:
          rigor plugin
          rigor plugin rigor-activesupport-core-ext
          rigor plugin --path rigor-activerecord
          rigor plugin --root
      USAGE

      # The pre-ADR-126 verbs, each with the spelling that replaces it.
      DEPRECATED_VERBS = {
        "list" => "rigor plugin --list",
        "path" => "rigor plugin --path <name>",
        "print" => "rigor plugin <name>",
        "root" => "rigor plugin --root"
      }.freeze

      # The bundled plugins/examples/source live at `<gem_root>/...`. From `lib/rigor/cli/plugin_command.rb` the gem
      # root is three directories up (matching SkillCommand::SKILLS_ROOT).
      GEM_ROOT     = File.expand_path("../../..", __dir__).freeze
      PLUGINS_ROOT = File.join(GEM_ROOT, "plugins").freeze
      EXAMPLES_ROOT = File.join(GEM_ROOT, "examples").freeze

      # The parser this command parses with, built without parsing anything: the catalogue reads its flags from it
      # (ADR-126 WD3). `options` is only written by the switches' blocks.
      def option_parser(options = {})
        OptionParser.new do |opts|
          opts.banner = USAGE.lines.first.chomp
          opts.on("--path NAME", "Print the absolute directory path of a plugin") { |value| options[:path] = value }
          opts.on("--list", "List bundled + example plugins") { options[:list] = true }
          opts.on("--root", "Print the gem root + key subdirectories") { options[:root] = true }
        end
      end

      # @return CLI exit status.
      def run
        if @argv.intersect?(%w[-h --help])
          @out.puts(USAGE)
          return 0
        end

        verb = @argv.first
        return run_deprecated_verb(@argv.shift) if DEPRECATED_VERBS.key?(verb)
        return run_help if verb == "help"

        run_grammar
      end

      private

      def run_help
        @out.puts(USAGE)
        0
      end

      def run_grammar
        options = {}
        option_parser(options).parse!(@argv)
        return run_path(options[:path]) if options.key?(:path)
        return run_root if options[:root]
        return run_list if options[:list]

        name = @argv.shift
        name.nil? ? run_list : run_print(name)
      end

      def run_deprecated_verb(verb)
        @err.puts("rigor: `rigor plugin #{verb}` is deprecated and will be removed in a future minor; " \
                  "use `#{DEPRECATED_VERBS.fetch(verb)}`.")
        case verb
        when "list" then run_list
        when "path" then run_path(@argv.shift)
        when "print" then run_print(@argv.shift)
        else run_root
        end
      end

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

      def run_path(name)
        return usage_error("`path` requires a plugin name") if name.nil?

        plugin = find(name)
        return name_error(name) if plugin.nil?

        @out.puts(plugin.fetch(:path))
        0
      end

      def run_print(name)
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

      # The header that precedes the plugin body when an author runs `rigor plugin <name>`. `# `-prefixed so the
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
          # `rigor plugin rigor-activesupport-core-ext`).
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

        RootedGlob.glob(dir, "lib/*.rb").min
      end

      def docker_note
        "\nNote: paths are local to where `rigor` runs. If you run rigor in a " \
          "container,\nread these files from the same filesystem (use " \
          "`rigor plugin <name>` to inline a body)."
      end

      def name_error(name)
        @err.puts("Unknown plugin: #{name}")
        @err.puts("Run `rigor plugin --list` to see the bundled plugins.")
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
