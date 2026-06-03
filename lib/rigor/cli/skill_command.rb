# frozen_string_literal: true

require_relative "command"

require "optparse"

module Rigor
  class CLI
    # `rigor skill` — discover and print the SKILL.md files
    # bundled with the `rigortype` gem.
    #
    # Rigor ships a small set of Agent Skills under `skills/` that
    # walk an AI coding agent through onboarding (`rigor-project-init`),
    # baseline reduction (`rigor-baseline-reduce`), and authoring a
    # plugin (`rigor-plugin-author`). When Rigor is installed via
    # `mise` / `gem install` / etc. the SKILL files live inside the
    # gem checkout — the project being analysed has no copy, so an
    # AI agent has no a priori way to find them.
    #
    # This command exposes the bundled skills via three subcommands:
    #
    # - `rigor skill list`         — table of name + absolute path.
    # - `rigor skill print <name>` — short header (paths + how to use)
    #                                followed by the SKILL.md body. This
    #                                is the form AI agents should call;
    #                                the inline body plus the header's
    #                                absolute paths together let the
    #                                agent act with or without a file
    #                                reading tool.
    # - `rigor skill path <name>`  — one-line absolute path, suitable
    #                                as input to a Read tool.
    #
    # `rigor skill` with no subcommand is an alias for `list`.
    class SkillCommand < Command
      USAGE = <<~USAGE
        Usage: rigor skill <subcommand> [args]

        Subcommands:
          list                  List bundled skills (default when no subcommand given)
          print <name>          Print the SKILL.md body for <name> to stdout, with a header
          path  <name>          Print the absolute path of the SKILL.md file for <name>

        Examples:
          rigor skill list
          rigor skill print rigor-project-init
          rigor skill path  rigor-baseline-reduce
      USAGE

      # The bundled skills live at `<gem_root>/skills/`. From
      # `lib/rigor/cli/skill_command.rb` that is three directories up.
      SKILLS_ROOT = File.expand_path("../../../skills", __dir__)

      # @return [Integer] CLI exit status.
      def run
        subcommand = @argv.shift || "list"

        case subcommand
        when "list" then run_list
        when "print" then run_print
        when "path" then run_path
        when "-h", "--help", "help"
          print_usage(@out)
          0
        else
          @err.puts("Unknown subcommand: #{subcommand}")
          print_usage(@err)
          Rigor::CLI::EXIT_USAGE
        end
      end

      private

      def run_list
        skills = discover_skills
        if skills.empty?
          @err.puts("No bundled skills found under #{SKILLS_ROOT}")
          return 1
        end

        width = skills.map { |s| s.fetch(:name).length }.max
        skills.each do |skill|
          @out.puts(format("%-#{width}s  %s", skill.fetch(:name), skill.fetch(:path)))
        end
        0
      end

      def run_print
        name = @argv.shift
        return usage_error("`print` requires a skill name") if name.nil?

        skill = find_skill(name)
        return name_error(name) if skill.nil?

        @out.puts(render_print_header(skill))
        @out.puts
        @out.write(File.read(skill.fetch(:path)))
        0
      end

      def run_path
        name = @argv.shift
        return usage_error("`path` requires a skill name") if name.nil?

        skill = find_skill(name)
        return name_error(name) if skill.nil?

        @out.puts(skill.fetch(:path))
        0
      end

      # The header that precedes the SKILL.md body when an agent
      # runs `rigor skill print <name>`. Kept as `# `-prefixed
      # comment lines so the combined output remains parseable as
      # markdown — anything below `---` (the SKILL frontmatter
      # marker) is unchanged.
      def render_print_header(skill)
        references_dir = File.join(File.dirname(skill.fetch(:path)), "references")
        ref_line = if File.directory?(references_dir)
                     "# References: #{references_dir}/  (read referenced `references/NN-*.md` files from here)"
                   else
                     "# References: (none)"
                   end
        <<~HEADER.chomp
          # Rigor skill: #{skill.fetch(:name)}
          # Source:     #{skill.fetch(:path)}
          #{ref_line}
          #
          # The body below is the canonical SKILL definition shipped with
          # rigortype #{Rigor::VERSION}. Follow its instructions.
        HEADER
      end

      def discover_skills
        return [] unless File.directory?(SKILLS_ROOT)

        Dir.children(SKILLS_ROOT).sort.filter_map do |name|
          skill_md = File.join(SKILLS_ROOT, name, "SKILL.md")
          next unless File.file?(skill_md)

          { name: name, path: skill_md }
        end
      end

      def find_skill(name)
        discover_skills.find { |s| s.fetch(:name) == name }
      end

      def name_error(name)
        @err.puts("Unknown skill: #{name}")
        @err.puts("Available skills:")
        discover_skills.each { |s| @err.puts("  #{s.fetch(:name)}") }
        1
      end

      def usage_error(message)
        @err.puts(message)
        print_usage(@err)
        Rigor::CLI::EXIT_USAGE
      end

      def print_usage(io)
        io.puts(USAGE)
      end
    end
  end
end
