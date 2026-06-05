# frozen_string_literal: true

module Rigor
  class CLI
    # Runtime CI-environment detection (ADR-51 WD7), modelled on
    # `OndraM/ci-detector` (the library PHPStan uses). Reads the well-known
    # environment variables a CI provider sets and returns the matching
    # {Platform}, classifying it into a **tier** that decides how
    # `rigor check` surfaces diagnostics there:
    #
    #   :native_stdout   — Rigor has a native format that renders purely from
    #                      stdout, so it is auto-emitted on top of the human
    #                      output (GitHub Actions → `github`, TeamCity →
    #                      `teamcity`). These are the first-class platforms.
    #   :native_artifact — Rigor has a native format but it needs a CI-wired
    #                      report artifact, not stdout (GitLab CI → `gitlab`).
    #                      First-class, but Rigor only *hints* the format.
    #   :reviewdog       — no native Rigor format; second-class, routed through
    #                      reviewdog (`checkstyle`/`sarif`) or `junit`. Hint
    #                      only.
    #
    # Detection is a pure function of the environment hash, so it is fully
    # testable; the CLI passes `ENV`. `RIGOR_CI_DETECT=0` (or `false`/`no`)
    # disables it globally — the seam the spec suite uses for determinism.
    module CiDetector
      Platform = Struct.new(:id, :name, :format, :tier, keyword_init: true) do
        def native_stdout? = tier == :native_stdout
        def native_artifact? = tier == :native_artifact
        def reviewdog? = tier == :reviewdog
      end

      # The detection table, ordered most-specific first so the generic
      # `CI=true` catch-all is last (a provider that also sets `CI` is still
      # recognised by its own variable). `match` is `:truthy` (value in
      # 1/true/yes/on), `:present` (variable set non-empty), or `:equals`.
      PROVIDERS = [
        { id: "github-actions", name: "GitHub Actions", format: "github", tier: :native_stdout,
          var: "GITHUB_ACTIONS", match: :truthy },
        { id: "gitlab", name: "GitLab CI", format: "gitlab", tier: :native_artifact,
          var: "GITLAB_CI", match: :truthy },
        { id: "teamcity", name: "TeamCity", format: "teamcity", tier: :native_stdout,
          var: "TEAMCITY_VERSION", match: :present },
        { id: "circleci", name: "CircleCI", format: nil, tier: :reviewdog,
          var: "CIRCLECI", match: :truthy },
        { id: "jenkins", name: "Jenkins", format: nil, tier: :reviewdog,
          var: "JENKINS_URL", match: :present },
        { id: "travis", name: "Travis CI", format: nil, tier: :reviewdog,
          var: "TRAVIS", match: :truthy },
        { id: "appveyor", name: "AppVeyor", format: nil, tier: :reviewdog,
          var: "APPVEYOR", match: :truthy },
        { id: "azure-pipelines", name: "Azure Pipelines", format: nil, tier: :reviewdog,
          var: "TF_BUILD", match: :present },
        { id: "bitbucket", name: "Bitbucket Pipelines", format: nil, tier: :reviewdog,
          var: "BITBUCKET_BUILD_NUMBER", match: :present },
        { id: "buildkite", name: "Buildkite", format: nil, tier: :reviewdog,
          var: "BUILDKITE", match: :truthy },
        { id: "drone", name: "Drone CI", format: nil, tier: :reviewdog,
          var: "DRONE", match: :truthy },
        { id: "semaphore", name: "Semaphore", format: nil, tier: :reviewdog,
          var: "SEMAPHORE", match: :truthy },
        { id: "codeship", name: "Codeship", format: nil, tier: :reviewdog,
          var: "CI_NAME", match: :equals, value: "codeship" },
        { id: "ci", name: "CI", format: nil, tier: :reviewdog,
          var: "CI", match: :truthy }
      ].freeze

      module_function

      # Returns the detected {Platform}, or nil when no CI is recognised or
      # detection is disabled via `RIGOR_CI_DETECT`.
      def detect(env = ENV)
        return nil if disabled?(env)

        row = PROVIDERS.find { |provider| matches?(env, provider) }
        return nil if row.nil?

        Platform.new(id: row[:id], name: row[:name], format: row[:format], tier: row[:tier])
      end

      def disabled?(env)
        %w[0 false no off].include?(env["RIGOR_CI_DETECT"].to_s.strip.downcase)
      end

      def matches?(env, provider)
        value = env[provider[:var]].to_s.strip
        case provider[:match]
        when :truthy then %w[1 true yes on].include?(value.downcase)
        when :present then !value.empty?
        when :equals then value.downcase == provider[:value]
        end
      end
    end
  end
end
