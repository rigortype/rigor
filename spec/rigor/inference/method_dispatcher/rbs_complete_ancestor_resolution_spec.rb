# frozen_string_literal: true

require "spec_helper"

# ADR-43 — RBS-complete ancestor resolution. A Ruby-source subclass of an allow-listed RBS-complete ancestor (seed
# `Rigor::Plugin::Base`) resolves its *inherited* method calls against that ancestor's RBS, so the normal call rules
# (here `call.undefined-method`) apply to misuse of the inherited contract surface. Every other RBS ancestor keeps the
# false-positive-safe `Dynamic[Top]` fallback.
RSpec.describe "ADR-43 RBS-complete ancestor resolution" do
  include RunnerHelpers

  # An RBS where the allow-listed `Rigor::Plugin::Base` declares an inherited method returning a closed core type
  # (`Integer`).
  let(:plugin_base_sig) do
    {
      "plugin_base.rbs" => <<~RBS
        module Rigor
          module Plugin
            class Base
              def contract_value: () -> Integer
            end
          end
        end
      RBS
    }
  end

  it "resolves an inherited method on the allow-listed ancestor (teeth: misuse fires undefined-method)" do
    result = analyze(<<~RUBY, sig: plugin_base_sig)
      module Rigor
        module Plugin
          class Demo < Rigor::Plugin::Base
            def go
              contract_value.no_such_method_on_integer
            end
          end
        end
      end
    RUBY

    undefined = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
    expect(undefined.size).to eq(1)
    expect(undefined.first.message).to include("no_such_method_on_integer")
  end

  it "does not false-positive on a valid call to the inherited-resolved type" do
    result = analyze(<<~RUBY, sig: plugin_base_sig)
      module Rigor
        module Plugin
          class Demo < Rigor::Plugin::Base
            def go
              contract_value.succ
            end
          end
        end
      end
    RUBY

    # `Integer#succ` exists — resolving `contract_value` to Integer must NOT manufacture a diagnostic on a real method.
    expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
  end

  it "leaves a NON-allow-listed RBS ancestor on the Dynamic fallback (no diagnostic)" do
    sig = {
      "open_base.rbs" => <<~RBS
        class OpenBase
          def contract_value: () -> Integer
        end
      RBS
    }

    result = analyze(<<~RUBY, sig: sig)
      class Demo < OpenBase
        def go
          contract_value.no_such_method_on_integer
        end
      end
    RUBY

    # `OpenBase` is not allow-listed, so the inherited call stays `Dynamic[Top]` and `call.undefined-method` must not
    # fire — the false-positive-safe behaviour that protects `< ActionController::Base`.
    expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
  end

  # #1572 — the bridge found the allow-listed ancestor breadth-first, so it reached the superclass before a module an
  # included module includes, and passed over an RBS-known module ahead of it; Ruby calls those first. `go` uses the
  # String Ruby returns, which the bridged Integer made a false positive; `bad` is a control on the same file.
  describe "an ancestor Ruby reaches ahead of the allow-listed one (#1572)" do
    let(:base_ruby) do
      "module Rigor\n  module Plugin\n    class Base\n      def contract_value = 1\n    end\n  end\nend\n"
    end

    def undefined_lines(source, sig)
      diagnostics = analyze(source, sig: sig, cache_store: nil).diagnostics
      diagnostics.select { |d| d.rule == "call.undefined-method" }.map(&:line)
    end

    it "does not bridge past a module an included module includes" do
      source = <<~RUBY
        module M
          def contract_value = "m"
        end
        module A
          include M
        end
        class Demo < Rigor::Plugin::Base
          include A
          def go = contract_value.upcase
        end
        "s".no_such_method_on_string
      RUBY
      expect(RubyRun.stdout("#{base_ruby}#{source.lines[0..9].join}p Demo.new.go\n")).to eq("\"M\"\n")
      expect(undefined_lines(source, plugin_base_sig)).to eq([11])
    end

    # The singleton side: an `extend`ed module sits ahead of the superclass's singleton, and the instance-only
    # include tier (#1173) does not answer it first.
    it "does not bridge past an RBS-known module the class extends that declares the name" do
      sig = {
        "base.rbs" => "module Rigor\n  module Plugin\n    class Base\n      def self.registry: () -> Integer\n    " \
                      "end\n  end\nend\n",
        "described.rbs" => "module Described\n  def registry: () -> String\nend\n"
      }
      source = <<~RUBY
        class Demo < Rigor::Plugin::Base
          extend Described
        end
        Demo.registry.upcase
        "s".no_such_method_on_string
      RUBY
      ruby = "module Rigor\n  module Plugin\n    class Base\n      def self.registry = 1\n    end\n  end\nend\n" \
             "module Described\n  def registry = \"d\"\nend\n#{source.lines[0..2].join}p Demo.registry.upcase\n"
      expect(RubyRun.stdout(ruby)).to eq("\"D\"\n")
      expect(undefined_lines(source, sig)).to eq([5])
    end

    it "still bridges past an RBS-known module that lacks the name (teeth: misuse fires)" do
      source = <<~RUBY
        class Demo < Rigor::Plugin::Base
          include Comparable
          def go = contract_value.no_such_method_on_integer
        end
      RUBY
      expect(undefined_lines(source, plugin_base_sig)).to eq([3])
    end
  end
end
