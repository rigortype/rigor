# frozen_string_literal: true

# Issue #728 — a rooted reopen that NAMES a mixin unioned its namespace ahead of the right ancestor.
#
# #721 stopped a site that names NO ancestor from contributing a header nesting, which closed the case
# where a bare `class ::Foo; def extra; end` inside `module Outer` resolved `Foo`'s superclass `Base` as
# `Outer::Base`. When the rooted reopen genuinely writes `include Helper` it is recorded, and a single
# chain per class then hands its `["Outer"]` to the superclass the TOP-LEVEL site wrote — the same wrong
# class on the same repro, so the residual union was never the conservative reading it was called.
#
# Ruby resolves each ancestor name in the cref of the site that wrote it, so the recorded chain is keyed by
# that name. Both arms are asserted: a fix that dropped the reopen's chain outright would answer `:top` for
# the superclass and lose `Helper` — which is why `h` is here.

require "spec_helper"
require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"

RSpec.describe "per-site header nesting (#728)" do
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
    Dir.mktmpdir("rigor-per-site-header-") { |dir| Dir.chdir(dir) { example.run } }
  end

  # The issue's own repro. MRI: `Foo.superclass == Base` (the top-level one) and `Foo.new.h == :h`.
  it "resolves a superclass at its own site while a rooted reopen's include resolves at the reopen's" do
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: :top", "dump_type: :h"])
      class Base
        def who = :top
      end

      class Foo < Base; end

      module Outer
        class Base
          def who = :outer
        end

        module Helper
          def h = :h
        end

        class ::Foo
          include Helper
        end
      end

      Rigor.dump_type(Foo.new.who)
      Rigor.dump_type(Foo.new.h)
    RUBY
  end

  # The case #721 closed, kept as a regression arm: the rooted reopen names NO ancestor, so it contributes
  # no chain at all and the top-level superclass site is the only one there is.
  it "keeps resolving a superclass when the rooted reopen names nothing" do
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: :top", "dump_type: 1"])
      class Base
        def who = :top
      end

      class Foo < Base; end

      module Outer
        class Base
          def who = :outer
        end

        class ::Foo
          def extra = 1
        end
      end

      Rigor.dump_type(Foo.new.who)
      Rigor.dump_type(Foo.new.extra)
    RUBY
  end

  # The must-still-succeed control: a class whose sites AGREE is unchanged, and an include written in the
  # ordinary nested spelling still resolves through the enclosing namespace.
  it "leaves a class whose sites share one cref unchanged" do
    expect(dumps_for(<<~RUBY)).to eq(["dump_type: :helped", "dump_type: :based"])
      module A
        module Helper
          def helped = :helped
        end

        class Base
          def based = :based
        end

        class Widget < Base
          include Helper
        end
      end

      Rigor.dump_type(A::Widget.new.helped)
      Rigor.dump_type(A::Widget.new.based)
    RUBY
  end
end
