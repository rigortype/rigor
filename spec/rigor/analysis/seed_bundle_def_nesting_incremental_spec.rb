# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #707 — the ADR-85 seed-bundle half of #681's recorded `Module.nesting`.
#
# #681 records each `def`'s chain in a discovery table keyed by `Prism::DefNode` IDENTITY, so the callee
# re-walk (`ExpressionTyper#build_user_method_body_scope`, which holds only the receiver's type) stamps the
# chain the declaration walk recorded rather than peeling the receiver's qualified name. A bundle stores rows,
# not nodes, and `DefNodeResolver` hands back a node from its OWN parse — an object no identity-keyed table
# built by the discovery walk can contain. So on the opt-in `--incremental` path a CHANGED file kept its chain
# while an UNCHANGED sibling served from its bundle fell back to the peel, and the two answered different
# constants for the same body.
#
# The failure is a DIVERGENCE, not a wrong absolute answer, so every example asserts BOTH arms:
#
# - the must-fire half — `Admin::CompactMaker#make` returns the top-level `::Post`, which has no `admin_post`,
#   so `call.undefined-method` MUST be reported by the warm recheck AND by the full-run oracle. On master the
#   warm arm loses it (the peel reaches `Admin::Post`, which declares `admin_post`), so an example asserting
#   only "warm == full" could pass on two coincidentally-equal sets; this one cannot.
# - the must-not-fire half — `top_post` IS declared on `::Post`, so neither arm may report it. That is the
#   original #707 false positive, and it is what master's warm arm actually produces.
RSpec.describe "ADR-85 seed bundles carry the recorded def nesting" do
  # The caller sorts FIRST so it is the file the incremental machinery re-analyses against a BUNDLED callee —
  # the ordering the issue's `--verify-incremental` reproduction uses.
  let(:reader) { "a_reader.rb" }
  let(:maker) { "z_maker.rb" }

  # The declaration is COMPACT (`class Admin::CompactMaker`), so Ruby's `Module.nesting` in `make` is
  # `["Admin::CompactMaker"]` and the bare `Post` names `::Post`. Peeling the qualified class name instead
  # yields `["Admin::CompactMaker", "Admin"]`, which reaches `Admin::Post` — the whole defect.
  let(:maker_source) do
    <<~RUBY
      class Post; end

      module Admin
        class Post; end
      end

      class Admin::CompactMaker
        def make = Post.new
      end
    RUBY
  end

  # `Post#top_post` and `Admin::Post#admin_post` are DISJOINT, so which class `make` returns is observable as
  # a diagnostic either way round.
  let(:sig_source) do
    <<~RBS
      class Post
        def top_post: () -> String
      end

      module Admin
        class Post
          def admin_post: () -> String
        end
      end
    RBS
  end

  # The one `call.undefined-method` a CORRECT reading produces: `make` returns `::Post`, which has no
  # `admin_post`. Present on every arm of every example below.
  let(:expected_sites) { ["#{reader}:3:call.undefined-method"] }
  let(:expected_messages) { ["undefined method `admin_post' for Post"] }

  # The diagnostic master's warm arm invents. Asserted absent explicitly rather than only implied by the
  # equality, so a future regression names itself.
  let(:peeled_message) { "undefined method `top_post' for Admin::Post" }
  # Issue #716 — the TOP-LEVEL half, which this file could not pin until the top-level chain became a
  # recorded answer. A previous comment here explained that it was unpinnable, and it was right for the tree
  # it described: `def helper = Post.new` at top level recorded NOTHING, both arms peeled the caller's
  # namespace, and cold agreed with warm on the same wrong constant — so an example asserting equality here
  # would have pinned `Admin::Post` where Ruby names `::Post`.
  #
  # Recording `[]` makes the cold answer right, and that is exactly what puts the warm arm at risk: `[]`
  # has to survive `live_defs_to_bundle` → Marshal → {Inference::DefHandle} → `DefNodeResolver` as `[]` and
  # not degrade to nil, which would silently restore the peel on every unchanged file. Mutating
  # `DefNodeResolver.record_nesting` back to skipping an empty chain fails this example, which is the claim
  # the older comment could not make.
  #
  # Both halves are asserted, so neither a lost diagnostic nor an invented one passes: `helper` returns
  # `::Post`, so `admin_post` MUST fire and `top_post` MUST NOT.
  let(:toplevel_maker_source) do
    <<~RUBY
      class Post; end

      module Admin
        class Post; end
      end

      def helper = Post.new
    RUBY
  end

  def reader_source(extra: nil)
    <<~RUBY
      class Reader
        def resolves = Admin::CompactMaker.new.make.top_post
        def misses = Admin::CompactMaker.new.make.admin_post
      #{"  def noise = #{extra}\n" if extra}end
    RUBY
  end

  # Writes the project (sources under `dir`, RBS under `dir/sig`) and returns its Configuration.
  def write_project(dir, extra: nil)
    File.write(File.join(dir, maker), maker_source)
    File.write(File.join(dir, reader), reader_source(extra: extra))
    signatures = File.join(dir, "sig")
    FileUtils.mkdir_p(signatures)
    File.write(File.join(signatures, "decl.rbs"), sig_source)
    Rigor::Configuration.new("paths" => [dir], "signature_paths" => [signatures])
  end

  def session_for(config, dir, environment)
    Rigor::Analysis::IncrementalSession.new(configuration: config, paths: [dir], environment: environment)
  end

  def environment_for(config)
    Rigor::Environment.for_project(signature_paths: config.signature_paths)
  end

  # `basename:line:rule` for every non-`:info` diagnostic, sorted — the shape both arms are compared in.
  def sites(diagnostics)
    diagnostics.reject { |d| d.severity == :info }
               .map { |d| "#{File.basename(d.path)}:#{d.line}:#{d.rule}" }.sort
  end

  def messages(diagnostics)
    diagnostics.reject { |d| d.severity == :info }.map(&:message).sort
  end

  def full_diagnostics(config, environment)
    guarded_run(
      Rigor::Analysis::Runner.new(configuration: config, cache_store: nil, environment: environment)
    ).diagnostics
  end

  it "answers the same constant on a warm recheck as on a full run, with the expected diagnostic on both" do
    Dir.mktmpdir do |dir|
      config = write_project(dir)
      environment = environment_for(config)
      session = session_for(config, dir, environment)
      expect(sites(guarded_baseline(session))).to eq(expected_sites)

      # Edit the CALLER only. The callee is unchanged, so its discovery contribution is served from the seed
      # bundle built during the baseline — the path that lost the chain.
      File.write(File.join(dir, reader), reader_source(extra: "1"))
      recheck = guarded_recheck(session)

      expect(recheck.reused).to include(File.join(dir, maker))
      expect(sites(recheck.diagnostics)).to eq(expected_sites)
      expect(messages(recheck.diagnostics)).to eq(expected_messages)
      expect(messages(recheck.diagnostics)).not_to include(peeled_message)
      expect(sites(recheck.diagnostics)).to eq(sites(full_diagnostics(config, environment)))
    end
  end

  it "carries the chain across the persisted snapshot, so a second PROCESS's warm run agrees too" do
    Dir.mktmpdir do |dir|
      config = write_project(dir)
      environment = environment_for(config)
      snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))
      fingerprint = Rigor::Cache::IncrementalSnapshot.fingerprint(configuration: config, roots: [dir])

      cold_session = session_for(config, dir, environment)
      cold, warm_first = guarded_run_incremental(cold_session, snapshot: snapshot, fingerprint: fingerprint)
      expect(warm_first).to be(false)
      expect(sites(cold)).to eq(expected_sites)

      # A fresh session reads the bundles back through Marshal — the arm that proves `nesting` survives the
      # blob rather than only the in-process hand-off.
      File.write(File.join(dir, reader), reader_source(extra: "2"))
      warm_session = session_for(config, dir, environment)
      warm, warm_second = guarded_run_incremental(warm_session, snapshot: snapshot, fingerprint: fingerprint)

      expect(warm_second).to be(true)
      expect(sites(warm)).to eq(expected_sites)
      expect(messages(warm)).to eq(expected_messages)
      expect(messages(warm)).not_to include(peeled_message)
      expect(sites(warm)).to eq(sites(full_diagnostics(config, environment)))
    end
  end

  def toplevel_reader_source(extra: nil)
    <<~RUBY
      module Admin
        class Reader
          def resolves = helper.top_post
          def misses = helper.admin_post
      #{"    def noise = #{extra}\n" if extra}  end
      end
    RUBY
  end

  def write_toplevel_project(dir, extra: nil)
    File.write(File.join(dir, maker), toplevel_maker_source)
    File.write(File.join(dir, reader), toplevel_reader_source(extra: extra))
    signatures = File.join(dir, "sig")
    FileUtils.mkdir_p(signatures)
    File.write(File.join(signatures, "decl.rbs"), sig_source)
    Rigor::Configuration.new("paths" => [dir], "signature_paths" => [signatures])
  end

  it "resolves a bundle-served top-level def's constants at the top level, as a full run does" do
    Dir.mktmpdir do |dir|
      config = write_toplevel_project(dir)
      environment = environment_for(config)
      session = session_for(config, dir, environment)
      expected = ["#{reader}:4:call.undefined-method"]
      expect(sites(guarded_baseline(session))).to eq(expected)

      # Edit the CALLER only, so the top-level def is served from the seed bundle built during the baseline.
      File.write(File.join(dir, reader), toplevel_reader_source(extra: "1"))
      recheck = guarded_recheck(session)

      expect(recheck.reused).to include(File.join(dir, maker))
      expect(sites(recheck.diagnostics)).to eq(expected)
      expect(messages(recheck.diagnostics)).to eq(["undefined method `admin_post' for Post"])
      expect(messages(recheck.diagnostics)).not_to include(peeled_message)
      expect(sites(recheck.diagnostics)).to eq(sites(full_diagnostics(config, environment)))
    end
  end
end
