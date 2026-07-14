# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

# ---------------------------------------------------------------
# GitHub Release automation
# ---------------------------------------------------------------
#
# `bundler/gem_tasks` provides `rake release` (guard-clean →
# build → tag → push → rubygems_push). We layer
# `rake release:github` on top: it reads the matching CHANGELOG
# section verbatim and creates a GitHub Release whose title is
# the section heading (`[x.y.z] - YYYY-MM-DD`) and whose body
# is the section text plus a `**Full Changelog**:` compare link.
#
# Hooked via `Rake::Task["release"].enhance do … end` so a full
# `rake release` invocation also creates the GitHub Release.
# Runs standalone as `rake release:github` to retry just this
# step when `rake release` succeeded but `gh release create`
# didn't (e.g. transient gh / network failure).
GITHUB_RELEASE_REPO = "rigortype/rigor"

namespace :release do
  desc "Create a GitHub Release from the matching CHANGELOG.md section"
  task :github do
    require "English"
    require_relative "lib/rigor/version"
    version = Rigor::VERSION
    tag = "v#{version}"

    unless system("git", "rev-parse", "--verify", "--quiet", "#{tag}^{tag}", out: File::NULL)
      abort "tag #{tag} not found locally — run `bundle exec rake release` first"
    end

    section = ReleaseHelpers.extract_changelog_section(version, "CHANGELOG.md")
    abort "no CHANGELOG section for [#{version}]" unless section

    title, body = section
    prev_tag = `git describe --tags --abbrev=0 "#{tag}^"`.strip
    abort "could not derive previous tag from #{tag}^" if prev_tag.empty? || !$CHILD_STATUS.success?

    compare = "https://github.com/#{GITHUB_RELEASE_REPO}/compare/#{prev_tag}...#{tag}"
    notes = "#{body}\n\n**Full Changelog**: #{compare}\n"

    require "tempfile"
    Tempfile.create(["rigor-release-notes-", ".md"]) do |f|
      f.write(notes)
      f.flush
      sh "gh", "release", "create", tag, "--title", title, "--notes-file", f.path
    end
  end
end

# ReleaseHelpers — extraction utilities for the GitHub Release
# task. Top-level method definitions in a Rakefile pollute Object,
# so the helper lives in a module and the task calls in via the
# explicit constant.
module ReleaseHelpers
  module_function

  # Returns `[title, body]` for `## [<version>] - YYYY-MM-DD` in
  # `path`, or nil when no such section exists. `title` is the
  # heading without the leading `## `; `body` is the section
  # text between the heading and the next `## [` heading, with
  # surrounding whitespace stripped.
  def extract_changelog_section(version, path)
    in_section = false
    title = nil
    body_lines = []

    File.foreach(path, encoding: "UTF-8") do |line|
      if line.start_with?("## [")
        break if in_section

        if line =~ /^## \[#{Regexp.escape(version)}\] - /
          in_section = true
          title = line.sub(/^## /, "").strip
          next
        end
      end
      body_lines << line if in_section
    end

    return nil unless title

    [title, body_lines.join.strip]
  end
end

# Run the GitHub Release step automatically after a full
# `rake release`. `Rake::Task#enhance` with a block appends to
# the task's actions (runs AFTER its body), so the GitHub
# Release fires only once the gem is tagged, pushed, and
# published to RubyGems. If this step fails, the gem is still
# released — re-run `rake release:github` standalone.
Rake::Task["release"].enhance do
  Rake::Task["release:github"].invoke
end
