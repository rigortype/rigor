# frozen_string_literal: true

# Integration spec for `examples/rigor-web/`. Reference coverage for the ADR-28 path-scoped method-protocol
# contract surface: the engine *provides* the contract's parameter type into a matching method body, and the
# plugin *checks* method presence plus return-type conformance.

require "spec_helper"

WEB_PLUGIN_LIB = File.expand_path("../../../examples/rigor-web/lib", __dir__)
$LOAD_PATH.unshift(WEB_PLUGIN_LIB) unless $LOAD_PATH.include?(WEB_PLUGIN_LIB)
require "rigor-web"

RSpec.describe "examples/rigor-web" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Web }

  # Materialises `files` into a tmpdir and analyses `paths`. The plugin contributes its own Rack RBS via
  # `signature_paths:`, so the spec does not pass any signatures itself.
  def run_web(files:, paths:, config: nil)
    plugin_entry = config ? { "gem" => "rigor-web", "config" => config } : "rigor-web"
    run_plugin(source: "# entry point unused\n", files: files, paths: paths, plugin_entry: plugin_entry)
  end

  describe "a protocol-conforming controller" do
    it "emits no plugin diagnostics" do
      result = run_web(
        files: {
          "lib/controller/home_controller.rb" => <<~RUBY
            class HomeController
              def get(request)
                Rack::Response.new(request.path_info, 200)
              end
            end
          RUBY
        },
        paths: ["lib/controller/home_controller.rb"]
      )
      expect(plugin_diagnostics(result)).to be_empty
    end
  end

  describe "a controller missing the protocol method" do
    it "flags missing-protocol-method" do
      result = run_web(
        files: {
          "lib/controller/silent_controller.rb" => <<~RUBY
            class SilentController
              def index(request)
                Rack::Response.new("x", 200)
              end
            end
          RUBY
        },
        paths: ["lib/controller/silent_controller.rb"]
      )
      diag = plugin_diagnostics(result).find { |d| d.rule == "missing-protocol-method" }
      expect(diag).not_to be_nil
      expect(diag.severity).to eq(:error)
      expect(diag.message).to include("SilentController", "`get`")
    end
  end

  describe "a controller whose #get returns the wrong type" do
    it "flags protocol-return-mismatch" do
      result = run_web(
        files: {
          "lib/controller/bad_controller.rb" => <<~RUBY
            class BadController
              def get(request)
                "plain text, not a Rack::Response"
              end
            end
          RUBY
        },
        paths: ["lib/controller/bad_controller.rb"]
      )
      diag = plugin_diagnostics(result).find { |d| d.rule == "protocol-return-mismatch" }
      expect(diag).not_to be_nil
      expect(diag.severity).to eq(:error)
      expect(diag.message).to include("`get`", "Rack::Response")
    end
  end

  describe "classes outside the contract path" do
    it "are not subject to the protocol" do
      result = run_web(
        files: {
          "lib/services/widget.rb" => <<~RUBY
            class Widget
              def index(request)
                "not a controller, not checked"
              end
            end
          RUBY
        },
        paths: ["lib/services/widget.rb"]
      )
      expect(plugin_diagnostics(result)).to be_empty
    end
  end

  # The provide half of the contract: inside a controller `#get`, the parameter is typed `Rack::Request`. The
  # same body misusing the request surfaces a core diagnostic ONLY when the file is under the contract path —
  # that difference proves the engine provides the parameter type.
  describe "parameter-type provision" do
    let(:body) do
      <<~RUBY
        class %<name>s
          def get(request)
            request.no_such_rack_method
            Rack::Response.new("ok", 200)
          end
        end
      RUBY
    end

    def core_diagnostics(result)
      result.diagnostics.reject { |d| d.source_family.to_s.start_with?("plugin.") }
    end

    it "surfaces a core diagnostic for request misuse inside a controller" do
      result = run_web(
        files: { "lib/controller/typo_controller.rb" => format(body, name: "TypoController") },
        paths: ["lib/controller/typo_controller.rb"]
      )
      offending = core_diagnostics(result).select { |d| d.message.include?("no_such_rack_method") }
      expect(offending).not_to be_empty
    end

    it "stays silent for the identical body outside the contract path" do
      result = run_web(
        files: { "lib/services/plain.rb" => format(body, name: "Plain") },
        paths: ["lib/services/plain.rb"]
      )
      offending = core_diagnostics(result).select { |d| d.message.include?("no_such_rack_method") }
      expect(offending).to be_empty
    end
  end

  describe "the controller_path config override" do
    let(:rails_controller) do
      {
        "app/controllers/orders_controller.rb" => <<~RUBY
          class OrdersController
            def index(request)
              Rack::Response.new("orders", 200)
            end
          end
        RUBY
      }
    end

    it "retargets the contract to the configured glob" do
      result = run_web(
        files: rails_controller,
        paths: ["app/controllers/orders_controller.rb"],
        config: { "controller_path" => "app/controllers/**/*.rb" }
      )
      diag = plugin_diagnostics(result).find { |d| d.rule == "missing-protocol-method" }
      expect(diag).not_to be_nil
      expect(diag.message).to include("OrdersController")
    end

    it "leaves the default glob non-matching for the same file" do
      result = run_web(
        files: rails_controller,
        paths: ["app/controllers/orders_controller.rb"]
      )
      expect(plugin_diagnostics(result)).to be_empty
    end
  end
end
