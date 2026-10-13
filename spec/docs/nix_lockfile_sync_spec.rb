# frozen_string_literal: true

# Gate #1849: the Nix package (`packages.default` in `flake.nix`, ADR-27's Nix install channel) installs
# the runtime gems resolved from `nix/Gemfile.lock` + `nix/gemset.nix`, while CI's suite and the release
# gate run the bundle in the repository root. The two sides are refreshed by different commands — the
# root by `bundle update`, the nix pair by `cd nix && bundle update && bundix` — so nothing coupled them,
# and `nix/Gemfile.lock` silently drifted to `rbs 4.0.2` / `language_server-protocol 3.17.0.5` while the
# root moved on. The shipped artifact then loaded a different `rbs` — the gem that supplies the core RBS
# the engine reads — than the suite exercised.
#
# Three invariants, because the nix side has three files that can each be left behind:
#   * every gem `nix/Gemfile.lock` resolves carries the version the root lock validates;
#   * `nix/gemset.nix` agrees with `nix/Gemfile.lock` (a `bundle update` without `bundix` updates the
#     lockfile and leaves the package on the old gems, which the root comparison alone cannot see);
#   * `nix/Gemfile` lists exactly the gemspec's runtime dependencies, so a new one cannot be forgotten.
# Both Ruby lockfiles are read with Bundler's own parser rather than re-deriving the format; `gemset.nix`
# is Nix syntax and is scanned for its per-gem `version` lines.
require "spec_helper"
require "bundler"

NIX_LOCK_REPO_ROOT = File.expand_path("../..", __dir__)
NIX_LOCK_NIX_GEMFILE_LOCK = File.join(NIX_LOCK_REPO_ROOT, "nix", "Gemfile.lock")
NIX_LOCK_GEMSET_NIX = File.join(NIX_LOCK_REPO_ROOT, "nix", "gemset.nix")
NIX_LOCK_REGENERATE = "Regenerate with `cd nix && bundle update && bundix` and commit the changed files."

RSpec.describe "nix/ package lockfile sync (#1849)" do
  def lock_specs(path)
    Bundler::LockfileParser.new(File.read(path)).specs.to_h { |spec| [spec.name, spec.version.to_s] }
  end

  # Each top-level gem is a `  name = { … `  };` block; the nested `source` block closes at four spaces,
  # so the two-space `  };` delimits the gem block.
  def gemset_versions(path)
    File.read(path).scan(/^  (?:"([^"]+)"|([\w.-]+)) = \{\n(.*?)^  \};/m).to_h do |quoted, bare, body|
      [quoted || bare, body[/^    version = "([^"]+)";$/, 1]]
    end
  end

  let(:root_specs) { lock_specs(File.join(NIX_LOCK_REPO_ROOT, "Gemfile.lock")) }
  let(:nix_specs) { lock_specs(NIX_LOCK_NIX_GEMFILE_LOCK) }
  let(:gemset_specs) { gemset_versions(NIX_LOCK_GEMSET_NIX) }

  it "reads every lockfile (guards a format change that would yield nothing)" do
    expect(root_specs).not_to be_empty
    expect(nix_specs.size).to be >= 3
    expect(gemset_specs.size).to eq(nix_specs.size)
    expect(gemset_specs.values).to all(be_a(String))
  end

  it "resolves every nix package gem to the version the root lock validates" do
    drift = nix_specs.filter_map do |name, version|
      root = root_specs[name]
      "#{name}: nix/ #{version}, root #{root || '(absent)'}" if root != version
    end

    expect(drift).to be_empty, <<~MESSAGE
      nix/Gemfile.lock disagrees with Gemfile.lock:
        #{drift.join("\n  ")}
      #{NIX_LOCK_REGENERATE}
    MESSAGE
  end

  it "keeps nix/gemset.nix in step with nix/Gemfile.lock" do
    drift = nix_specs.filter_map do |name, version|
      gemset = gemset_specs[name]
      "#{name}: gemset.nix #{gemset || '(absent)'}, lock #{version}" if gemset != version
    end

    expect(drift).to be_empty, <<~MESSAGE
      nix/gemset.nix is stale against nix/Gemfile.lock:
        #{drift.join("\n  ")}
      #{NIX_LOCK_REGENERATE}
    MESSAGE
  end

  it "mirrors the gemspec's runtime dependencies in nix/Gemfile" do
    gemspec = Gem::Specification.load(File.join(NIX_LOCK_REPO_ROOT, "rigortype.gemspec"))
    runtime = gemspec.dependencies.select { |dep| dep.type == :runtime }.map(&:name).sort
    declared = Bundler::LockfileParser.new(File.read(NIX_LOCK_NIX_GEMFILE_LOCK)).dependencies.keys.sort

    expect(declared).to eq(runtime), <<~MESSAGE
      nix/Gemfile must list exactly the gemspec's runtime dependencies.
        nix/Gemfile: #{declared.inspect}
        gemspec:     #{runtime.inspect}
    MESSAGE
  end
end
