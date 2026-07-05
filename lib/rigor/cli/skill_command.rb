# frozen_string_literal: true

require_relative "command"

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
    # Grammar (mirrors `rigor docs`): the positional slot is always a
    # skill *name*; alternative outputs are flags, so a skill named
    # `list` or `path` can never be shadowed by a verb.
    #
    # - `rigor skill`              — list bundled skills (the default).
    # - `rigor skill <name>`       — print the SKILL.md body (header + body).
    #                                This is the form AI agents call; the
    #                                inline body plus the header's absolute
    #                                paths let the agent act with or without
    #                                a file-reading tool.
    # - `rigor skill --full <name>`— the body AND every `references/*.md`
    #                                inline: the complete, version-current
    #                                procedure in one call. The thinned SKILL
    #                                bodies point a *frozen* (vendored) copy
    #                                at this so the reader follows the gem's
    #                                current steps, not a stale local copy.
    # - `rigor skill --path <name>`— one-line absolute path, for a Read tool.
    # - `rigor skill --list`       — table of name + absolute path.
    # - `rigor skill --describe`   — ADR-73's live entry point: a cheap
    #                                project-state probe + the recommended
    #                                next skill + every skill's current
    #                                description. The `rigor-next-steps`
    #                                SKILL routes off this so no
    #                                version-coupled guidance is frozen into
    #                                the SKILL. Also spelled `describe`, and
    #                                surfaced top-level as `rigor describe`.
    #
    # The pre-v0.3.0 verb spellings `rigor skill list` / `print <name>` /
    # `path <name>` still work but emit a stderr deprecation notice; they
    # are removed in v0.3.0 (see docs/ROADMAP.md § "Scheduled CLI
    # deprecations"). `describe` is a no-argument action, not a name-slot
    # verb, so it stays first-class alongside `--describe`.
    class SkillCommand < Command
      USAGE = <<~USAGE
        Usage: rigor skill [<name>] [--full <name>] [--path <name>] [--list] [--describe]

        With no argument, lists the bundled skills.

          rigor skill                List bundled skills
          rigor skill <name>         Print the SKILL.md body for <name> (with a header)
          rigor skill --full <name>  Print the SKILL.md body AND its references/ inline
                                     (the complete, version-current procedure in one call)
          rigor skill --path <name>  Print the absolute path of the SKILL.md file for <name>
          rigor skill --list         List bundled skills (name + absolute path)
          rigor skill --describe     Report project state + recommend the next skill to run

        Examples:
          rigor skill
          rigor skill rigor-project-init
          rigor skill --full rigor-baseline-reduce
          rigor skill --path rigor-baseline-reduce
          rigor skill --describe        (also: rigor describe)

        Deprecated (removed in v0.3.0) — use the forms above:
          rigor skill list           ->  rigor skill --list
          rigor skill print <name>   ->  rigor skill <name>
          rigor skill path <name>    ->  rigor skill --path <name>
      USAGE

      # The bundled skills live at `<gem_root>/skills/`. From
      # `lib/rigor/cli/skill_command.rb` that is three directories up.
      SKILLS_ROOT = File.expand_path("../../../skills", __dir__)

      # The verb subcommands the flags superseded keep working with a
      # stderr deprecation notice until this version drops them. Each maps
      # to the canonical advice printed and the flag it rewrites to.
      LEGACY_VERB_REMOVAL = "v0.3.0"
      LEGACY_VERBS = {
        "list" => { old: "list",         advice: "--list", flag: "--list" },
        "print" => { old: "print <name>", advice: "<name>", flag: "--print" },
        "path" => { old: "path <name>", advice: "--path <name>", flag: "--path" }
      }.freeze

      # @return [Integer] CLI exit status.
      def run
        rewrite_legacy_verb!

        case @argv.first
        when nil
          run_list
        when "-h", "--help", "help"
          print_usage(@out)
          0
        when "describe", "--describe"
          @argv.shift
          run_describe
        when "--list"
          @argv.shift
          run_list
        when "--full"
          @argv.shift
          run_full(@argv.shift)
        when "--path"
          @argv.shift
          run_path(@argv.shift)
        when "--print"
          @argv.shift
          run_print(@argv.shift)
        else
          run_print(@argv.shift)
        end
      end

      private

      # Translate a deprecated verb spelling into its flag form, warning
      # once on stderr, so the dispatch above only handles canonical forms.
      def rewrite_legacy_verb!
        spec = LEGACY_VERBS[@argv.first]
        return unless spec

        @err.puts(
          "rigor skill: `#{spec.fetch(:old)}` is deprecated and will be removed in " \
          "#{LEGACY_VERB_REMOVAL}; use `rigor skill #{spec.fetch(:advice)}` instead."
        )
        @argv[0] = spec.fetch(:flag)
      end

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

      def run_print(name)
        return usage_error("a skill name is required") if name.nil?

        skill = find_skill(name)
        return name_error(name) if skill.nil?

        @out.puts(render_print_header(skill))
        @out.puts
        @out.write(File.read(skill.fetch(:path)))
        0
      end

      # `rigor skill --full <name>` — the whole current procedure in one
      # call: the SKILL.md body followed by each `references/*.md` inline.
      # This is what the thinned SKILL bodies point a *frozen* copy at — a
      # vendored copy of a skill (installed via `npx skills`) may lag the
      # gem, so re-fetching the complete body here guarantees the reader
      # follows the version that shipped with the installed Rigor, without
      # needing a file-reading tool or reading a possibly-stale co-located
      # `references/`.
      def run_full(name)
        return usage_error("`--full` requires a skill name") if name.nil?

        skill = find_skill(name)
        return name_error(name) if skill.nil?

        @out.puts(render_print_header(skill))
        @out.puts
        @out.write(File.read(skill.fetch(:path)))

        reference_files(skill).each do |ref|
          @out.puts
          @out.puts
          @out.puts("<!-- ===== references/#{File.basename(ref)} (bundled with rigortype #{Rigor::VERSION}) ===== -->")
          @out.puts
          @out.write(File.read(ref))
        end
        0
      end

      def run_path(name)
        return usage_error("`--path` requires a skill name") if name.nil?

        skill = find_skill(name)
        return name_error(name) if skill.nil?

        @out.puts(skill.fetch(:path))
        0
      end

      # `rigor skill --describe` (also spelled `describe`) — ADR-73's
      # live "brain", delegated to {SkillDescribe}: it probes the current
      # project's state with cheap presence checks (it never runs `rigor
      # check`), recommends the next skill to run, and prints every
      # bundled skill's current frontmatter description, so the
      # `rigor-next-steps` SKILL can route without copying any
      # version-coupled guidance into itself.
      def run_describe
        require_relative "skill_describe"

        @out.puts(SkillDescribe.new(skills: discover_skills).render)
        0
      end

      # The header that precedes the SKILL.md body when an agent
      # runs `rigor skill <name>`. Kept as `# `-prefixed comment lines
      # so the combined output remains parseable as markdown — anything
      # below `---` (the SKILL frontmatter marker) is unchanged.
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

      # The `references/*.md` files bundled alongside a skill, sorted so the
      # `NN-` prefixes drive read order.
      def reference_files(skill)
        dir = File.join(File.dirname(skill.fetch(:path)), "references")
        return [] unless File.directory?(dir)

        # `Dir.glob` returns lexicographically sorted paths (Ruby 3.0+),
        # so the `NN-` prefixes already drive read order.
        Dir.glob(File.join(dir, "*.md"))
      end

      def name_error(name)
        @err.puts("Unknown skill: #{name}")
        @err.puts("Available skills (try `rigor skill --list`):")
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
