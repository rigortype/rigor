# frozen_string_literal: true

# Integration spec for `plugins/rigor-hanami/`.
# Validates the ADR-28 provide-and-check pair for Hanami
# actions: the engine provides `Hanami::Action::Request` /
# `Hanami::Action::Response` into `#handle` bodies, and the
# plugin checks that every class under `app/actions/` defines
# `#handle`.

require "spec_helper"

HANAMI_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-hanami/lib", __dir__)
$LOAD_PATH.unshift(HANAMI_PLUGIN_LIB) unless $LOAD_PATH.include?(HANAMI_PLUGIN_LIB)
require "rigor-hanami"

RSpec.describe "plugins/rigor-hanami" do
  before { Rigor::Plugin.unregister! }
  after  { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Hanami }

  # Materialises `files` into a tmpdir and analyses `paths`.
  # The plugin contributes Hanami Action RBS via `signature_paths:`
  # so no external sig is needed.
  def run_hanami(files:, paths:, config: nil)
    plugin_entry = config ? { "gem" => "rigor-hanami", "config" => config } : "rigor-hanami"
    run_plugin(source: "# entry point\n", files: files, paths: paths, plugin_entry: plugin_entry)
  end

  describe "a conforming action" do
    it "emits no plugin diagnostics" do
      result = run_hanami(
        files: {
          "app/actions/books/index.rb" => <<~RUBY
            module Bookshelf
              module Actions
                module Books
                  class Index
                    def handle(request, response)
                      response.status = 200
                    end
                  end
                end
              end
            end
          RUBY
        },
        paths: ["app/actions/books/index.rb"]
      )
      expect(plugin_diagnostics(result)).to be_empty
    end
  end

  describe "an action class missing #handle" do
    it "flags missing-handle-method" do
      result = run_hanami(
        files: {
          "app/actions/books/index.rb" => <<~RUBY
            module Bookshelf
              module Actions
                module Books
                  class Index
                    def show(id)
                      id
                    end
                  end
                end
              end
            end
          RUBY
        },
        paths: ["app/actions/books/index.rb"]
      )
      diag = plugin_diagnostics(result).find { |d| d.rule == "missing-handle-method" }
      expect(diag).not_to be_nil
      expect(diag.severity).to eq(:error)
      expect(diag.message).to include("Index", "#handle")
    end
  end

  describe "classes outside the action path" do
    it "are not subject to the protocol" do
      result = run_hanami(
        files: {
          "app/operations/create_book.rb" => <<~RUBY
            class CreateBook
              def call(params)
                params
              end
            end
          RUBY
        },
        paths: ["app/operations/create_book.rb"]
      )
      expect(plugin_diagnostics(result)).to be_empty
    end
  end

  # Proves the engine provides Hanami::Action::Request / Response
  # types into the #handle body: calling a non-existent method on
  # request surfaces a core diagnostic when the file is under the
  # action path, but stays silent when it is outside.
  describe "parameter-type provision" do
    let(:body) do
      <<~RUBY
        module Bookshelf
          module Actions
            class %<name>s
              def handle(request, response)
                request.no_such_hanami_method
                response.status = 200
              end
            end
          end
        end
      RUBY
    end

    def core_diagnostics(result)
      result.diagnostics.reject { |d| d.source_family.to_s.start_with?("plugin.") }
    end

    it "surfaces a core diagnostic for request misuse inside an action" do
      result = run_hanami(
        files: {
          "app/actions/typo_action.rb" => format(body, name: "TypoAction")
        },
        paths: ["app/actions/typo_action.rb"]
      )
      offending = core_diagnostics(result).select { |d| d.message.include?("no_such_hanami_method") }
      expect(offending).not_to be_empty
    end

    it "stays silent for the identical body outside the action path" do
      result = run_hanami(
        files: {
          "app/operations/plain.rb" => format(body, name: "Plain")
        },
        paths: ["app/operations/plain.rb"]
      )
      offending = core_diagnostics(result).select { |d| d.message.include?("no_such_hanami_method") }
      expect(offending).to be_empty
    end
  end

  describe "the action_path config override" do
    let(:slice_action) do
      {
        "slices/main/actions/home/index.rb" => <<~RUBY
          class HomeIndex
            def show(id)
              id
            end
          end
        RUBY
      }
    end

    it "retargets the contract to the configured glob" do
      result = run_hanami(
        files: slice_action,
        paths: ["slices/main/actions/home/index.rb"],
        config: { "action_path" => "slices/main/actions/**/*.rb" }
      )
      diag = plugin_diagnostics(result).find { |d| d.rule == "missing-handle-method" }
      expect(diag).not_to be_nil
      expect(diag.message).to include("HomeIndex")
    end

    it "leaves the default glob non-matching for the same file" do
      result = run_hanami(
        files: slice_action,
        paths: ["slices/main/actions/home/index.rb"]
      )
      expect(plugin_diagnostics(result)).to be_empty
    end
  end
end
