# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #316 — the project-wide `<toplevel>` def table let a top-level `def output` in one file capture RSpec's
# `output` matcher in an unrelated spec file. At runtime the included module's public method beats a private
# top-level `Object` def, so the code is correct; the analyzer bound the call to the helper (which returns `nil`
# via `print`) and fired `undefined method 'to_stdout_from_any_process' for nil` on the chain.
#
# The fix is a confidence rule on `Scope#bindable_top_level_def_for`: inside a block whose `self` is unmodelled,
# a top-level `def` from ANOTHER file is not evidence about which method the call reaches, so the bind is
# declined and the call widens. Both halves of the boundary are pinned here, and every silence assertion is
# paired with a still-fires sibling — a decline-only spec passes on a build that stopped analyzing at all.
RSpec.describe "toplevel def captured by a DSL block" do
  def diagnostics_for(files)
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      files.each { |name, source| File.write(File.join(lib, name), source) }
      runner = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new("paths" => [lib]),
        cache_store: nil
      )
      guarded_run(runner).diagnostics.reject { |d| d.path.to_s.end_with?(".rigor.yml") }
    end
  end

  def messages_for(files) = diagnostics_for(files).map(&:message)
  def rules_for(files) = diagnostics_for(files).map(&:rule)

  def helper_source = <<~RUBY
    def output(obj)
      print obj.to_s
    end
  RUBY

  def matcher_spec_source = <<~RUBY
    RSpec.describe "x" do
      it "prints" do
        expect { puts "ok" }.to output(/ok/).to_stdout_from_any_process
      end
    end
  RUBY

  it "does not fire on the issue's two-file repro" do
    expect(messages_for("helper.rb" => helper_source, "a_spec.rb" => matcher_spec_source))
      .not_to include(/to_stdout_from_any_process/)
  end

  # The instrument can say "yes": the same chain called from GENUINE top-level code still binds the cross-file
  # helper and still types its `nil` return, so the undefined-method rule fires.
  it "still types a cross-file toplevel helper called from toplevel code" do
    expect(messages_for("helper.rb" => helper_source, "script.rb" => <<~RUBY))
      output("x").to_stdout_from_any_process
    RUBY
      .to include(/to_stdout_from_any_process/)
  end

  # The other side of the file boundary: a `def` collocated with its DSL-block call site is part of one lexical
  # structure (the v0.0.3 A / #319 case), so it keeps binding and a real error on its return still fires.
  it "still binds a toplevel def defined in the same file as the DSL block" do
    expect(messages_for("same.rb" => <<~RUBY)).to include(/upcase/)
      RSpec.describe "y" do
        def local_helper
          7
        end

        it "uses it" do
          local_helper.upcase
        end
      end
    RUBY
  end

  # Issue #600 — the decline survived exactly until the first branch merge. `Scope#join` omitted
  # `opaque_block_self` from the joined scope's constructor call, so it fell back to `false` and any `if` /
  # `case` / `while` inside the block re-armed the bind for everything after it. The repro is the issue's
  # two-file one with an `if` spliced in ahead of the matcher, and it must stay as silent as the version
  # without it.
  it "keeps declining after a branch merge inside the DSL block" do
    spliced = <<~RUBY
      RSpec.describe "x" do
        it "prints" do
          if [true, false].sample
            x = 1
          else
            x = 2
          end
          expect { puts x }.to output(/ok/).to_stdout_from_any_process
        end
      end
    RUBY

    expect(messages_for("helper.rb" => helper_source, "a_spec.rb" => spliced))
      .not_to include(/to_stdout_from_any_process/)
  end

  # The must-bind sibling, so the example above cannot pass on a build that simply stopped binding anything
  # after an `if`: the same merge in genuine top-level code still binds the cross-file helper, still types its
  # `nil` return, and still fires.
  it "still binds a cross-file toplevel helper after a merge outside any block" do
    expect(messages_for("helper.rb" => helper_source, "script.rb" => <<~RUBY)).to include(/to_stdout_from_any_process/)
      if [true, false].sample
        y = 1
      else
        y = 2
      end
      output(y).to_stdout_from_any_process
    RUBY
  end

  # The decline must not be paid for with a new `call.unresolved-toplevel` on the declined name: the
  # suppression side keeps reading the unrestricted table, so a name the project defines at the top level is
  # never reported as unresolved. (`it` / `expect` warn here for the unrelated reason that nothing in the run
  # defines them, which is what makes this assertion a name test rather than a rule-absence test.)
  it "does not trade the silenced bind for an unresolved-toplevel warning on the declined name" do
    unresolved = diagnostics_for("helper.rb" => helper_source, "a_spec.rb" => matcher_spec_source)
                 .select { |d| d.rule == "call.unresolved-toplevel" }

    expect(unresolved.map(&:message)).to all(satisfy { |m| !m.include?("`output`") })
    expect(unresolved).not_to be_empty
  end

  it "still warns about a genuinely undefined toplevel call" do
    expect(rules_for("script.rb" => "genuinely_undefined_helper(1)"))
      .to include("call.unresolved-toplevel")
  end

  describe Rigor::Scope do
    it "marks a block body as carrying an unmodelled self" do
      program = Prism.parse(<<~RUBY).value
        [1, 2].each do |n|
          p n
        end
      RUBY
      index = Rigor::Inference::ScopeIndexer.index(program, default_scope: described_class.empty)
      inner = program.statements.body.first.block.body.body.first

      expect(index[inner].opaque_block_self?).to be(true)
      expect(index[program].opaque_block_self?).to be(false)
    end
  end
end
