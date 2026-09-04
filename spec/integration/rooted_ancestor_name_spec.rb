# frozen_string_literal: true

# Issue #722 residue 1 / #637 — a ROOTED ancestor name is anchored at the top level.
#
# `Source::ConstantPath.qualified_name` renders segments only, so `class Rooted < ::Base` recorded the same
# `"Base"` a bare `< Base` does. The resolver then walked the enclosing nesting and answered `A::Base` — a
# class Ruby never looks at, on the one spelling whose entire purpose is to opt out of that walk.
#
# `declaration_prefix` already re-anchors a rooted HEADER (#708 / #638). This is the same rule for the
# ancestor NAME the header writes, carried as a leading `::` on the recorded value and stripped by the three
# resolvers that read it: `Scope#ancestor_name_candidates` (the single owner since #682) and the two older
# peels that resolve their own child/parent pair.
#
# `Class.new(::Parent)` is NOT covered: marking it changed nothing observable, so the anonymous class's
# ancestry is reached by a path that does not read the recorded value. That residue stays on #722.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "a rooted ancestor name (#722 residue 1)" do
  def dumps_for(source)
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "demo.rb"), source)
    configuration = Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge("paths" => %w[lib], "workers" => 0)
    )
    result = guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[lib]
    )
    result.diagnostics.select { |d| d.qualified_rule == "dump.type" }.map(&:message)
  end

  around do |example|
    Dir.mktmpdir("rigor-rooted-ancestor-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "resolves a rooted superclass at the top level, and a bare one lexically" do
    # Both spellings in one fixture, under a namespace that SHADOWS the top-level name — without the
    # shadow neither answer distinguishes anything.
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: :top_val", "dump_type: :a_val"])
      class Base
        def top_val = :top_val
      end

      module A
        class Base
          def a_val = :a_val
        end

        class Rooted < ::Base
          def probe = Rigor.dump_type(top_val)
        end

        class Nested < Base
          def probe = Rigor.dump_type(a_val)
        end
      end
    RUBY
  end

  it "resolves a rooted superclass through a qualified path" do
    # `::Outer::Base` is a rooted PATH, not a bare rooted name: `rooted?` answers at the leftmost segment,
    # and the marker has to survive the multi-segment render.
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: :outer_val"])
      module Outer
        class Base
          def outer_val = :outer_val
        end
      end

      module A
        module Outer
          class Base
            def shadow_val = :shadow_val
          end
        end

        class Rooted < ::Outer::Base
          def probe = Rigor.dump_type(outer_val)
        end
      end
    RUBY
  end

  it "still walks the nesting for an unrooted ancestor that only the namespace defines" do
    # Mandatory control: the marker must not turn every ancestor name into a top-level lookup. `Helper` is
    # defined ONLY under `A`, so a fix that anchored unconditionally would lose it.
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: :helped"])
      module A
        module Helper
          def helped = :helped
        end

        class Host
          include Helper

          def probe = Rigor.dump_type(helped)
        end
      end
    RUBY
  end
end
