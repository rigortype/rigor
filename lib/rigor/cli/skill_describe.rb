# frozen_string_literal: true

require "yaml"

module Rigor
  class CLI
    # Builds the `rigor skill describe` report (ADR-73): a cheap,
    # presence-only project-state probe, a recommended next skill, and
    # the live catalogue of bundled skills with their current frontmatter
    # descriptions. Extracted from {SkillCommand} so the command stays a
    # thin dispatcher and this — the "live brain" — owns the routing.
    #
    # It runs no analysis: the recommendation needs only presence
    # signals, and a full check is the downstream skill's job. The report
    # is read-only (it stats files and opens only the CI configs), so an
    # agent can run it freely at any point.
    class SkillDescribe
      # Config / baseline filenames the state probe stats for.
      # `CONFIG_FILENAMES` mirrors `Configuration::DISCOVERY_ORDER`
      # (developer-local override first, committed default second) so the
      # probe agrees with what `rigor check` would auto-discover.
      CONFIG_FILENAMES = %w[.rigor.yml .rigor.dist.yml].freeze
      BASELINE_FILENAME = ".rigor-baseline.yml"

      # The entry-point SKILL itself — excluded from the catalogue
      # because it is the skill being run, not a destination.
      ENTRY_POINT_SKILL = "rigor-next-steps"

      # Adoption-journey order for the catalogue and the order the
      # recommendation decision tree walks.
      CATALOG_ORDER = %w[
        rigor-project-init
        rigor-ci-setup
        rigor-baseline-reduce
        rigor-protection-uplift
        rigor-plugin-author
      ].freeze

      # @param skills [Array<Hash>] discovered skills, each `{name:, path:}`.
      # @param root [String] project root to probe (defaults to the cwd).
      def initialize(skills:, root: Dir.pwd)
        @skills = skills
        @root = root
      end

      # @return [String] the full describe report.
      def render
        catalog = catalog_skills
        state = project_state
        recommendation = recommend(state, catalog)
        [
          title,
          state_section(state),
          recommendation_section(recommendation),
          catalog_section(catalog),
          agent_prompt(recommendation)
        ].join("\n")
      end

      private

      # The skills offered as "what to do next", in adoption-journey
      # order. The entry-point skill is excluded, and unknown skills sort
      # after the known journey, alphabetically.
      def catalog_skills
        @skills
          .reject { |skill| skill.fetch(:name) == ENTRY_POINT_SKILL }
          .sort_by { |skill| [CATALOG_ORDER.index(skill.fetch(:name)) || CATALOG_ORDER.size, skill.fetch(:name)] }
      end

      def project_state
        {
          config: CONFIG_FILENAMES.find { |name| File.file?(File.join(@root, name)) },
          baseline: File.file?(File.join(@root, BASELINE_FILENAME)),
          sig: File.directory?(File.join(@root, "sig")),
          ci: ci_state
        }
      end

      # `:wired` (a CI config mentions `rigor`), `:unwired` (a CI config
      # exists but does not), or `:none`.
      def ci_state
        files = ci_config_files
        return :none if files.empty?

        files.any? { |path| ci_file_mentions_rigor?(path) } ? :wired : :unwired
      end

      def ci_file_mentions_rigor?(path)
        File.read(path).include?("rigor")
      rescue StandardError
        false
      end

      def ci_config_files
        files = Dir.glob(File.join(@root, ".github", "workflows", "*.{yml,yaml}"))
        gitlab = File.join(@root, ".gitlab-ci.yml")
        files << gitlab if File.file?(gitlab)
        files
      end

      # The decision tree (ADR-73 WD2). Returns `{ skill:, reason: }` for
      # the recommended next step, or nil when no catalogue skill matches.
      def recommend(state, catalog)
        name, reason = recommended_name_and_reason(state)
        skill = catalog.find { |candidate| candidate.fetch(:name) == name }
        skill.nil? ? nil : { skill: skill, reason: reason }
      end

      def recommended_name_and_reason(state)
        if state.fetch(:config).nil?
          ["rigor-project-init", "this project has no Rigor configuration yet — start here."]
        elsif state.fetch(:ci) != :wired
          ["rigor-ci-setup", "Rigor is configured but not wired into CI — lock in the regression guard."]
        elsif state.fetch(:baseline)
          ["rigor-baseline-reduce", "a baseline is in place — work it down rule by rule."]
        else
          ["rigor-protection-uplift", "the basics are in place — raise how much of your code Rigor can catch bugs in."]
        end
      end

      def title
        <<~TITLE
          # Rigor — next steps for this project
          #
          # Generated live by rigortype #{Rigor::VERSION}; this guidance always
          # reflects your installed version and the project's current state.
        TITLE
      end

      def state_section(state)
        ci = case state.fetch(:ci)
             when :wired then "Rigor wired in"
             when :unwired then "CI present, Rigor not wired"
             else "not detected"
             end
        <<~STATE
          ## Project state
          - Config file:    #{state.fetch(:config) || 'none (no .rigor.yml / .rigor.dist.yml)'}
          - Baseline:       #{state.fetch(:baseline) ? BASELINE_FILENAME : 'none'}
          - Project sig/:   #{state.fetch(:sig) ? 'present' : 'none'}
          - CI integration: #{ci}
        STATE
      end

      def recommendation_section(recommendation)
        return "## Recommended next step\n- (no bundled skill matched the current state)\n" if recommendation.nil?

        name = recommendation.fetch(:skill).fetch(:name)
        <<~REC
          ## Recommended next step
          → #{name} — #{recommendation.fetch(:reason)}
            Load it: rigor skill print #{name}
        REC
      end

      def catalog_section(catalog)
        lines = catalog.map do |skill|
          name = skill.fetch(:name)
          "- #{name} — #{catalog_blurb(skill.fetch(:path))}\n  rigor skill print #{name}"
        end
        "## All skills you can run next\n#{lines.join("\n")}\n"
      end

      def agent_prompt(recommendation)
        opener =
          if recommendation.nil?
            "Ask the user what they would like to do next"
          else
            "Present the recommended step above (or, if the user has a different goal, ask which they want)"
          end
        <<~PROMPT
          ## For the agent
          #{opener}, then run `rigor skill print <name>` for the chosen skill and
          follow its body top to bottom. Re-run `rigor skill describe` whenever you
          need the next step — it always reflects the project's current state.
        PROMPT
      end

      # The one-line essence of a skill's frontmatter `description`, read
      # live from the SKILL.md so the catalogue can never go stale
      # relative to the shipped skill. Drops the `Triggers:` / `NOT for`
      # tail and caps the length.
      def catalog_blurb(path)
        text = frontmatter(path).fetch("description", "").to_s.strip.tr("\n", " ").squeeze(" ")
        head = text.split(/\s*Triggers?:/, 2).first.to_s.strip
        head = text if head.empty?
        truncate(head, 200)
      end

      def truncate(text, limit)
        return text if text.length <= limit

        "#{(text[0, limit] || '').rstrip}…"
      end

      # Parse a SKILL.md's leading `---`-delimited YAML frontmatter.
      # Returns {} on any missing or malformed block so the catalogue
      # degrades to a name-only entry rather than raising.
      def frontmatter(path)
        text = File.read(path)
        return {} unless text.start_with?("---\n")

        closing = text.index("\n---\n", 4)
        return {} if closing.nil?

        data = YAML.safe_load(text[4...closing])
        data.is_a?(Hash) ? data : {}
      rescue StandardError
        {}
      end
    end
  end
end
