# frozen_string_literal: true

# Gates `bin/verify-changed`'s fixture→spec selection (#3171). A changed file
# under a fixtures/ tree is matched by the directory path that identifies it:
# `demo.rb` sits in dozens of fixture directories, and matching its basename
# stem selected ~97 spec files for a one-file change. `--list-specs` prints the
# selection without running the checks; VERIFY_CHANGED_PATHS stands the diff in,
# so the examples read the real tree and never run RSpec through the script.
#
# The nonexistent fixture names below are spelled apart so this file does not
# select itself: every literal here is a word the selection greps for.
require "open3"
require "spec_helper"

RSpec.describe "bin/verify-changed spec selection" do
  let(:script) { File.expand_path("../../bin/verify-changed", __dir__) }
  let(:root) { File.expand_path("../..", __dir__) }

  # [selected spec paths, uncovered fixture paths] for the given changed paths.
  def selection_for(*paths)
    env = { "VERIFY_CHANGED_PATHS" => paths.join("\n") }
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3(env, script, "HEAD", "--list-specs", chdir: root)
    end
    expect(status.exitstatus).to eq(0), "#{out}\n#{err}"
    specs = out.lines.map(&:strip).reject(&:empty?)
    uncovered = err.scan(/^ {2}- (\S+) \(/).flatten
    [specs, uncovered]
  end

  it "selects few specs for one fixture's demo.rb, by its directory" do
    specs, uncovered = selection_for("spec/integration/fixtures/block_content_ivar_capture/demo.rb")
    expect(uncovered).to be_empty
    expect(specs.length).to be <= 10
    expect(specs).to include("spec/integration/type_construction_spec.rb")
    # The stem match this replaces also selected every spec that merely says "demo".
    expect(specs).not_to include("spec/rigor/plugin_spec.rb")
  end

  it "keeps the stem match for a flat fixture with a distinctive name" do
    specs, uncovered = selection_for("spec/integration/fixtures/and_assign_narrowing.rb")
    expect(uncovered).to be_empty
    expect(specs).to include("spec/integration/type_construction_spec.rb")
  end

  it "matches a nested fixture by the directory prefix specs name" do
    specs, uncovered = selection_for("spec/integration/fixtures/interface_parity/joins/sig/joins.rbs")
    expect(uncovered).to be_empty
    expect(specs).to include("spec/integration/interface_parity_spec.rb")
    expect(specs.length).to be <= 5
  end

  it "reaches a container fixture's own specs, not the whole container" do
    specs, uncovered = selection_for("spec/integration/fixtures/effects/tracer/loud.rb")
    expect(uncovered).to be_empty
    expect(specs).to include("spec/rigor/effects/tracer_collection_spec.rb")
    expect(specs).not_to include("spec/rigor/effects/rails_layer_spec.rb")
  end

  it "falls back to the stem when no directory prefix names a spec" do
    ghost = %w[no_such_fixture 3171].join("_")
    specs, uncovered = selection_for("spec/integration/fixtures/#{ghost}/demo.rb")
    expect(uncovered).to be_empty
    expect(specs).not_to be_empty
  end

  it "reports a fixture nothing names instead of selecting silently" do
    dir = %w[no_such_fixture 3171].join("_")
    file = %w[unique_name 3171].join("_")
    path = "spec/integration/fixtures/#{dir}/#{file}.rb"
    specs, uncovered = selection_for(path)
    expect(specs).to be_empty
    expect(uncovered).to include(path)
  end
end
