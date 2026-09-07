# frozen_string_literal: true

require "yaml"

module Rigor
  class CLI
    # The presence-only project-state probe behind `rigor skill describe` (ADR-73 WD2). It stats files and opens only
    # config / CI / lockfiles — it runs no analysis — so it is cheap and side-effect-free, and an agent can run it
    # freely at any point. Split from {SkillDescribe} so the routing/rendering class stays focused.
    class ProjectStateProbe
      # Config / baseline filenames the probe stats for. `CONFIG_FILENAMES` mirrors `Configuration::DISCOVERY_ORDER`
      # (developer-local override first, committed default second) so the probe agrees with what `rigor check` would
      # auto-discover.
      CONFIG_FILENAMES = %w[.rigor.yml .rigor.dist.yml].freeze
      BASELINE_FILENAME = ".rigor-baseline.yml"
      # `rbs collection install`'s lockfile — Rigor auto-detects it at the project root and feeds each gem's community
      # RBS into the signature paths, so its presence is the signal that the gem-RBS gap has been addressed.
      RBS_COLLECTION_LOCKFILE = "rbs_collection.lock.yaml"

      # `Gemfile.lock` substrings that mark a Rails app, and the bundled Rails-family plugin ids — used to spot a
      # configured Rails project that has not enabled any Rails plugin (a `rigor-plugin-tune` cue).
      RAILS_LOCK_MARKERS = %w[railties actionpack activerecord actioncable].freeze
      RAILS_PLUGIN_MARKERS = %w[
        rigor-activerecord rigor-actionpack rigor-actionmailer rigor-activejob
        rigor-rails-routes rigor-rails-i18n rigor-actioncable rigor-activestorage rigor-rails
      ].freeze

      def initialize(root)
        @root = root
      end

      # @rbs return: Hash[untyped, untyped] -- The presence-only state the recommendation routes on.
      def to_h
        config = CONFIG_FILENAMES.find { |name| File.file?(File.join(@root, name)) }
        {
          config: config,
          baseline: File.file?(File.join(@root, BASELINE_FILENAME)),
          sig: File.directory?(File.join(@root, "sig")),
          gems: File.file?(File.join(@root, "Gemfile.lock")),
          rbs_collection: File.file?(File.join(@root, RBS_COLLECTION_LOCKFILE)),
          rails_unconfigured: rails_unconfigured?(config),
          ci: ci_state,
          editor: editor_state,
          mcp: mcp_state
        }
      end

      private

      # True when Rails is in `Gemfile.lock` but the (present) config enables no Rails plugin — so `rigor-plugin-tune`
      # (wiring the ActiveRecord / routes / i18n plugins) buys more than community RBS would (the 20260620 field trial's
      # strap case). Only fires on an already-configured project; an un-configured Rails app routes to
      # `rigor-project-init`, which selects the plugins itself.
      def rails_unconfigured?(config)
        return false if config.nil?

        lock = File.join(@root, "Gemfile.lock")
        return false unless File.file?(lock) && file_mentions_any?(lock, RAILS_LOCK_MARKERS)

        !file_mentions_any?(File.join(@root, config), RAILS_PLUGIN_MARKERS)
      end

      def file_mentions_any?(path, markers)
        content = File.read(path)
        markers.any? { |marker| content.include?(marker) }
      rescue StandardError
        false
      end

      # `:wired` (a CI config mentions `rigor`), `:unwired` (a CI config exists but does not), or `:none`.
      def ci_state
        files = ci_config_files
        return :none if files.empty?

        files.any? { |path| file_mentions_rigor?(path) } ? :wired : :unwired
      end

      # Editor-LSP signal — `:wired` (a committed `.vscode/` config names `rigor`), `:unwired` (a `.vscode/` is present
      # but does not), or `:none`. Only VS Code is detectable here: Neovim / Emacs / Helix configs live in the user's
      # home, not the repo, so editor-setup is otherwise a catalogue-only destination.
      def editor_state
        vscode = File.join(@root, ".vscode")
        return :none unless File.directory?(vscode)

        files = Dir.glob(File.join(vscode, "*.json"))
        return :unwired if files.empty?

        files.any? { |path| file_mentions_rigor?(path) } ? :wired : :unwired
      end

      # MCP-client signal — `:wired` (a committed project MCP config names `rigor`), `:unwired` (one is present but does
      # not), or `:none`. Only the project-scoped configs are detectable (`.mcp.json`, `.cursor/mcp.json`); user-level
      # client configs live in $HOME, so mcp-setup is otherwise a catalogue-only destination.
      def mcp_state
        files = [".mcp.json", File.join(".cursor", "mcp.json")]
                .map { |rel| File.join(@root, rel) }
                .select { |path| File.file?(path) }
        return :none if files.empty?

        files.any? { |path| file_mentions_rigor?(path) } ? :wired : :unwired
      end

      def file_mentions_rigor?(path)
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
    end

    # Builds the `rigor skill describe` report (ADR-73): a {ProjectStateProbe} snapshot, a recommended next skill, and
    # the live catalogue of bundled skills with their current frontmatter descriptions. Extracted from {SkillCommand} so
    # the command stays a thin dispatcher and this — the "live brain" — owns the routing.
    class SkillDescribe
      # The entry-point SKILL itself — excluded from the catalogue because it is the skill being run, not a destination.
      ENTRY_POINT_SKILL = "rigor-next-steps"

      # Adoption-journey order for the catalogue and the order the recommendation decision tree walks. `rigor-ask` sits
      # last: it is the journey-agnostic "answer a question about Rigor" companion the agent can offer at any point,
      # never a presence-recommended step.
      CATALOG_ORDER = %w[
        rigor-project-init
        rigor-rbs-setup
        rigor-ci-setup
        rigor-baseline-reduce
        rigor-monkeypatch-resolve
        rigor-editor-setup
        rigor-mcp-setup
        rigor-protection-uplift
        rigor-plugin-tune
        rigor-plugin-author
        rigor-upgrade
        rigor-doctor
        rigor-ask
      ].freeze

      # @rbs skills: Array[Hash[untyped, untyped]] -- Discovered skills, each `{name:, path:}`.
      # @rbs root: String -- Project root to probe (defaults to the cwd).
      # @rbs deep: bool --
      #   Opt into `--deep`: run a real `rigor check` and let its result pick the headline. Off by default, and off is
      #   ADR-73 WD2's contract — see {SkillDeepProbe} for why the whole analysis path lives behind this one flag and
      #   in its own file.
      def initialize(skills:, root: Dir.pwd, deep: false)
        @skills = skills
        @root = root
        @deep = deep
      end

      # @rbs return: String -- The full describe report.
      def render
        catalog = catalog_skills
        state = ProjectStateProbe.new(@root).to_h
        deep = deep_report(state)
        recommendation = recommend(state, catalog, deep)
        [
          title,
          state_section(state),
          deep_section(deep),
          recommendation_section(recommendation),
          catalog_section(catalog),
          agent_prompt(recommendation, deep)
        ].compact.join("\n")
      end

      private

      # The `--deep` analysis, or nil when the flag was not given. `require` sits here rather than at the top of the
      # file so the default, presence-only path never even loads the check-invocation plumbing — WD2's "runs no
      # analysis" guarantee is enforced by what gets loaded, not only by what gets called.
      def deep_report(state)
        return nil unless @deep

        require_relative "skill_deep_probe"
        SkillDeepProbe.new(config: state.fetch(:config), root: @root).run
      end

      # The skills offered as "what to do next", in adoption-journey order. The entry-point skill is excluded, and
      # unknown skills sort after the known journey, alphabetically.
      def catalog_skills
        @skills
          .reject { |skill| skill.fetch(:name) == ENTRY_POINT_SKILL }
          .sort_by { |skill| [CATALOG_ORDER.index(skill.fetch(:name)) || CATALOG_ORDER.size, skill.fetch(:name)] }
      end

      # The decision tree (ADR-73 WD2). Returns `{ skill:, reason: }` for the recommended next step, or nil when no
      # catalogue skill matches.
      #
      # A `--deep` report overrides the presence-only tree only when it actually routed: a check that was skipped,
      # could not run, or ran clean leaves the tree's answer standing untouched. So the un-flagged behaviour is
      # literally the `deep == nil` branch of this one method.
      def recommend(state, catalog, deep = nil)
        name, reason = deep&.route ? [deep.route, deep.reason] : recommended_name_and_reason(state)
        skill = catalog.find { |candidate| candidate.fetch(:name) == name }
        skill.nil? ? nil : { skill: skill, reason: reason }
      end

      def recommended_name_and_reason(state)
        if state.fetch(:config).nil?
          ["rigor-project-init", "this project has no Rigor configuration yet — start here."]
        elsif state.fetch(:rails_unconfigured)
          ["rigor-plugin-tune",
           "Rails is in your Gemfile.lock but no Rails plugins are enabled — wire them so " \
           "ActiveRecord / routes / i18n calls resolve (a bigger win here than community RBS)."]
        elsif state.fetch(:gems) && !state.fetch(:rbs_collection)
          ["rigor-rbs-setup", "your gems ship no community RBS yet — install it so Rigor stops typing them as Dynamic."]
        elsif state.fetch(:ci) != :wired
          ["rigor-ci-setup", "Rigor is configured but not wired into CI — lock in the regression guard."]
        # A present baseline is deliberately NOT a recommendation trigger. A baseline is a healthy, finished onboarding
        # state, not a problem to work off; pushing every baselined project to "reduce it" turns a working build into a
        # chore and tempts scattering `# rigor:disable` through the code to make a number go down — means over ends.
        # `rigor-baseline-reduce` stays in the catalogue for the intermediate user who *chooses* to invest in it; the
        # headline routes to genuinely additive steps instead.
        elsif state.fetch(:editor) == :unwired
          ["rigor-editor-setup",
           "you have an editor config but no Rigor LSP — wire `rigor lsp` for live diagnostics and hover types."]
        elsif state.fetch(:mcp) == :unwired
          ["rigor-mcp-setup",
           "an MCP client config is present without Rigor — wire `rigor mcp` so your AI agent can call Rigor's tools."]
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
        rbs = if state.fetch(:gems)
                state.fetch(:rbs_collection) ? "collection installed" : "gems present, no collection"
              else
                "no Gemfile.lock"
              end
        editor = case state.fetch(:editor)
                 when :wired then "Rigor LSP wired (.vscode)"
                 when :unwired then ".vscode present, Rigor LSP not wired"
                 else "not detected"
                 end
        mcp = case state.fetch(:mcp)
              when :wired then "Rigor MCP wired"
              when :unwired then "MCP config present, Rigor not wired"
              else "not detected"
              end
        <<~STATE
          ## Project state
          - Config file:    #{state.fetch(:config) || 'none (no .rigor.yml / .rigor.dist.yml)'}
          - Baseline:       #{state.fetch(:baseline) ? '.rigor-baseline.yml' : 'none'}
          - Project sig/:   #{state.fetch(:sig) ? 'present' : 'none'}
          - Community RBS:  #{rbs}
          - CI integration: #{ci}
          - Editor LSP:     #{editor}
          - MCP server:     #{mcp}
        STATE
      end

      # Printed only under `--deep`, so the un-flagged report is byte-identical to what it has always been.
      def deep_section(deep)
        return nil if deep.nil?

        <<~DEEP
          ## Deep check (--deep)
          A real `rigor check` was run for this recommendation — unlike the probe above it
          is slow and it writes `.rigor/cache`, exactly as `rigor check` does.
          - Result: #{deep.detail}
        DEEP
      end

      def recommendation_section(recommendation)
        return "## Recommended next step\n- (no bundled skill matched the current state)\n" if recommendation.nil?

        name = recommendation.fetch(:skill).fetch(:name)
        <<~REC
          ## Recommended next step
          → #{name} — #{recommendation.fetch(:reason)}
            Load it: rigor skill #{name}
        REC
      end

      def catalog_section(catalog)
        lines = catalog.map do |skill|
          name = skill.fetch(:name)
          "- #{name} — #{catalog_blurb(skill.fetch(:path))}\n  rigor skill #{name}"
        end
        "## All skills you can run next\n#{lines.join("\n")}\n"
      end

      def agent_prompt(recommendation, deep = nil)
        opener =
          if recommendation.nil?
            "Ask the user what they would like to do next"
          else
            "Present the recommended step above (or, if the user has a different goal, ask which they want)"
          end
        <<~PROMPT
          ## For the agent
          #{opener}, then run `rigor skill <name>` for the chosen skill and
          follow its body top to bottom.

          #{check_awareness(deep)}

          Re-run `rigor skill describe` whenever you need the next step — it always
          reflects the project's current state.
        PROMPT
      end

      # The check-aware routing block. Without `--deep` it teaches the agent to make the call itself from a check it
      # has already run (the 2026-06-20 field-trial fix, unchanged); with `--deep` the headline already made that
      # call, so the block reports what happened instead of re-teaching it. The routing vocabulary is one taxonomy
      # shared by both branches and by {SkillDeepProbe}.
      def check_awareness(deep)
        return presence_only_check_awareness if deep.nil?
        return deep_failure_check_awareness if deep.failed?

        <<~DEEP.chomp
          The recommendation above already factors in the `--deep` check result, using the
          same routing this command teaches without `--deep`: proven project monkey-patches
          → rigor-monkeypatch-resolve; `RBS classes available: 0` or a `configuration-error`
          → rigor-doctor; remaining error diagnostics → rigor-baseline-reduce. It does not
          route on weaker signals (framework calls typing as Dynamic → rigor-plugin-tune is
          still yours to judge from the check output).
        DEEP
      end

      def presence_only_check_awareness
        <<~PROMPT.chomp
          The recommendation above is from a presence-only probe — it does not run
          `rigor check`. If you have run (or now run) `rigor check`, let its findings
          refine the choice:
          - a `call.unresolved-toplevel` / `call.undefined-method` cluster on the
            project's own monkey-patches → rigor-monkeypatch-resolve
          - framework calls (ActiveRecord, routes, i18n …) typing as Dynamic with no
            matching plugins enabled → rigor-plugin-tune
          - `RBS classes available: 0` or a `configuration-error` diagnostic → rigor-doctor
          (`rigor skill describe --deep` runs that check for you and applies this routing
          to the headline itself — at the cost of a full analysis.)
        PROMPT
      end

      def deep_failure_check_awareness
        <<~PROMPT.chomp
          The `--deep` check did NOT complete, so the recommendation above is the
          presence-only one. Do not treat the project as clean: run `rigor doctor`
          (or `rigor check`) and fix what it reports before trusting any routing.
        PROMPT
      end

      # The one-line essence of a skill's frontmatter `description`, read live from the SKILL.md so the catalogue can
      # never go stale relative to the shipped skill. Drops the `Triggers:` / `NOT for` tail and caps the length.
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

      # Parse a SKILL.md's leading `---`-delimited YAML frontmatter. Returns {} on any missing or malformed block so the
      # catalogue degrades to a name-only entry rather than raising.
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
