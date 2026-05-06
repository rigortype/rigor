# frozen_string_literal: true

# Integration spec for `examples/rigor-statesman/`. Reference
# coverage for the two-pass DSL analysis pattern (collect
# declarations, then validate references).

require "spec_helper"

STATESMAN_PLUGIN_LIB = File.expand_path("../../../examples/rigor-statesman/lib", __dir__)
$LOAD_PATH.unshift(STATESMAN_PLUGIN_LIB) unless $LOAD_PATH.include?(STATESMAN_PLUGIN_LIB)
require "rigor-statesman"

RSpec.describe "examples/rigor-statesman" do # rubocop:disable RSpec/DescribeClass
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Statesman }
  let(:requirer) do
    lambda do |_name|
      Rigor::Plugin.register(plugin_class)
      true
    end
  end
  let(:state_machine_source) do
    <<~RUBY
      class Order
        state_machine do
          state :draft, initial: true
          state :submitted
          state :approved
          state :rejected
        end
      end
    RUBY
  end

  def run_plugin(source, plugin_config: nil)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "demo.rb"), source.end_with?("\n") ? source : "#{source}\n")
      plugin_entry = plugin_config ? { "gem" => "rigor-statesman", "config" => plugin_config } : "rigor-statesman"
      configuration = Rigor::Configuration.new(
        Rigor::Configuration::DEFAULTS.merge(
          "paths" => [File.join(dir, "demo.rb")],
          "plugins" => [plugin_entry]
        )
      )
      Rigor::Analysis::Runner.new(
        configuration: configuration,
        cache_store: nil,
        plugin_requirer: requirer
      ).run
    end
  end

  def plugin_diagnostics(result)
    result.diagnostics.select { |d| d.source_family == "plugin.statesman" }
  end

  describe "transition validation" do
    it "marks a known transition as :info" do
      diags = plugin_diagnostics(run_plugin("#{state_machine_source}order.transition_to(:submitted)"))
      info = diags.find { |d| d.rule == "known-state" }
      expect(info).not_to be_nil
      expect(info.severity).to eq(:info)
      expect(info.message).to eq("transition_to(:submitted) — declared state")
    end

    it "errors on a typo with a Levenshtein-suggested neighbour" do
      diags = plugin_diagnostics(run_plugin("#{state_machine_source}order.transition_to(:approval)"))
      err = diags.find { |d| d.rule == "unknown-state" }
      expect(err.severity).to eq(:error)
      expect(err.message).to eq("unknown state :approval (did you mean :approved?)")
    end

    it "errors without a hint when no state is close enough" do
      diags = plugin_diagnostics(run_plugin("#{state_machine_source}order.transition_to(:purgatory)"))
      err = diags.find { |d| d.rule == "unknown-state" }
      expect(err.message).to eq("unknown state :purgatory")
    end

    it "stays silent on non-Symbol arguments" do
      diags = plugin_diagnostics(run_plugin(<<~RUBY))
        #{state_machine_source}
        target = :submitted
        order.transition_to(target)
      RUBY
      expect(diags.select { |d| d.rule == "unknown-state" }).to be_empty
    end
  end

  describe "no-state-machine files" do
    it "stays completely silent when the file has no state_machine block" do
      diags = plugin_diagnostics(run_plugin("order.transition_to(:foo)"))
      expect(diags).to be_empty
    end
  end

  describe "configurable DSL keywords" do
    it "treats configured `dsl_method` / `state_method` / `transition_method` as the DSL" do # rubocop:disable RSpec/ExampleLength
      source = <<~RUBY
        class Order
          aasm do
            permit :draft, initial: true
            permit :ready
          end
        end

        order.advance_to(:ready)
        order.advance_to(:rdy)
      RUBY

      diags = plugin_diagnostics(run_plugin(
                                   source,
                                   plugin_config: {
                                     "dsl_method" => "aasm",
                                     "state_method" => "permit",
                                     "transition_method" => "advance_to"
                                   }
                                 ))

      expect(diags.find { |d| d.rule == "known-state" }.message)
        .to eq("advance_to(:ready) — declared state")
      expect(diags.find { |d| d.rule == "unknown-state" }.message)
        .to eq("unknown state :rdy (did you mean :ready?)")
    end
  end

  describe "multiple state machines in the same file" do
    it "unions the state sets across all state_machine blocks" do # rubocop:disable RSpec/ExampleLength
      diags = plugin_diagnostics(run_plugin(<<~RUBY))
        class Order
          state_machine do
            state :pending, initial: true
            state :paid
          end
        end
        class Subscription
          state_machine do
            state :trialing, initial: true
            state :active
          end
        end

        order.transition_to(:paid)
        subscription.transition_to(:trialing)
      RUBY

      known = diags.select { |d| d.rule == "known-state" }
      expect(known.size).to eq(2)
    end
  end
end
