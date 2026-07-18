# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::CiDetector do
  def detect(env)
    described_class.detect(env)
  end

  describe "first-class platforms" do
    it "detects GitHub Actions as a native stdout platform (github)" do
      platform = detect("GITHUB_ACTIONS" => "true")

      expect(platform.id).to eq("github-actions")
      expect(platform.format).to eq("github")
      expect(platform).to be_native_stdout
    end

    it "detects TeamCity as a native stdout platform (teamcity)" do
      platform = detect("TEAMCITY_VERSION" => "2024.03")

      expect(platform.id).to eq("teamcity")
      expect(platform.format).to eq("teamcity")
      expect(platform).to be_native_stdout
    end

    it "detects GitLab CI as a native artifact platform (gitlab)" do
      platform = detect("GITLAB_CI" => "true")

      expect(platform.id).to eq("gitlab")
      expect(platform.format).to eq("gitlab")
      expect(platform).to be_native_artifact
    end
  end

  describe "second-class (reviewdog-routed) platforms" do
    {
      "CircleCI" => { "CIRCLECI" => "true" },
      "Jenkins" => { "JENKINS_URL" => "https://ci.example/" },
      "Travis CI" => { "TRAVIS" => "true" },
      "Azure Pipelines" => { "TF_BUILD" => "True" },
      "Bitbucket Pipelines" => { "BITBUCKET_BUILD_NUMBER" => "42" },
      "Buildkite" => { "BUILDKITE" => "true" },
      "Drone CI" => { "DRONE" => "true" }
    }.each do |name, env|
      it "detects #{name} with no native format" do
        platform = detect(env)

        expect(platform.name).to eq(name)
        expect(platform.format).to be_nil
        expect(platform).to be_reviewdog
      end
    end

    it "falls back to a generic CI for a bare CI=true" do
      platform = detect("CI" => "true")

      expect(platform.id).to eq("ci")
      expect(platform).to be_reviewdog
    end
  end

  describe "precedence and negatives" do
    it "prefers the specific provider over the generic CI flag" do
      expect(detect("CI" => "true", "GITHUB_ACTIONS" => "true").id).to eq("github-actions")
    end

    it "returns nil when no CI marker is present" do
      expect(detect({})).to be_nil
    end

    it "ignores a falsey provider flag" do
      expect(detect("GITHUB_ACTIONS" => "false")).to be_nil
    end

    it "is disabled by RIGOR_CI_DETECT=0 even under a detected CI" do
      expect(detect("GITHUB_ACTIONS" => "true", "RIGOR_CI_DETECT" => "0")).to be_nil
    end

    it "is disabled by RIGOR_CI_DETECT=false / no / off" do
      %w[false no off].each do |value|
        expect(detect("CI" => "true", "RIGOR_CI_DETECT" => value)).to be_nil
      end
    end
  end
end
