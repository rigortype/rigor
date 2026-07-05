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
end
