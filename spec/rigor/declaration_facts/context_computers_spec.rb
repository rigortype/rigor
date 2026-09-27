# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "yaml"

# #1507 — the declaration-context tripwire. A Ruby file under `lib/` or `plugins/*/lib/` whose code names
# `Prism::ClassNode`, `Prism::ModuleNode` or `Prism::SingletonClassNode` decides for itself what a class body
# is. This spec computes that set from the tree and compares it with `context_computers.yml`, so a new file fails
# until it is listed with what it computes and the helper it uses, and a file that stops dispatching must leave
# the list.
RSpec.describe "Declaration-context computers" do
  let(:allowlist) { YAML.load_file(File.join(__dir__, "context_computers.yml")) }

  dispatch = /\bPrism::(?:ClassNode|ModuleNode|SingletonClassNode)\b/
  helper = /\A(?:DeclarationWalk::Context|ModuleFunctionState|own: \S.*)\z/
  helper_names = { "DeclarationWalk::Context" => "DeclarationWalk", "ModuleFunctionState" => "ModuleFunctionState" }

  define_method(:dispatching) do |code|
    code.select { |_, text| text.match?(dispatch) }.keys.sort
  end

  define_method(:tripwire_problems) do |found, listed|
    (found - listed).map { |path| "#{path}: dispatches on a declaration node and is not in context_computers.yml" } +
      (listed - found).map { |path| "#{path}: listed in context_computers.yml but no longer dispatches" }
  end

  define_method(:entry_problems) do |path, entry, code|
    helpers = entry["helpers"]
    problems = []
    problems << "#{path}: no computes" unless entry["computes"].is_a?(String) && !entry["computes"].strip.empty?
    unless helpers.is_a?(Array) && !helpers.empty? && helpers.all? { |h| h.is_a?(String) && h.match?(helper) }
      return problems << "#{path}: helpers must list DeclarationWalk::Context, ModuleFunctionState or own: <reason>"
    end

    problems + helper_use_problems(path, helpers, code)
  end

  # A listed helper the file never names, or a helper the file names without listing it.
  define_method(:helper_use_problems) do |path, helpers, code|
    helper_names.flat_map do |name, needle|
      listed = helpers.include?(name)
      next ["#{path}: lists #{name} but never names #{needle}"] if listed && !code.include?(needle)
      next ["#{path}: names #{needle} but does not list #{name}"] if !listed && code.include?(needle)

      []
    end
  end

  it "lists exactly the files that dispatch on a declaration node" do
    found = dispatching(DeclarationFactSources.code_under)

    expect(tripwire_problems(found, allowlist.keys.sort)).to eq([])
  end

  it "says what each listed file computes and which helper it uses" do
    code = DeclarationFactSources.code_under
    problems = allowlist.flat_map { |path, entry| entry_problems(path, entry, code.fetch(path, "")) }

    expect(problems).to eq([])
  end

  describe "the tripwire itself" do
    it "fails on a new dispatching file" do
      mutated = DeclarationFactSources.code_under.merge("lib/rigor/new_walker.rb" => "when Prism::ModuleNode then 1\n")

      expect(tripwire_problems(dispatching(mutated), allowlist.keys.sort))
        .to eq(["lib/rigor/new_walker.rb: dispatches on a declaration node and is not in context_computers.yml"])
    end

    it "fails on a listed file that no longer dispatches" do
      expect(tripwire_problems(["lib/a.rb"], ["lib/a.rb", "lib/gone.rb"]))
        .to eq(["lib/gone.rb: listed in context_computers.yml but no longer dispatches"])
    end

    it "reads lib/ and plugins/*/lib/ from disk, and skips comment lines and plugin specs" do
      Dir.mktmpdir do |dir|
        {
          "lib/a.rb" => "x if node.is_a?(Prism::ClassNode)\n",
          "lib/comment_only.rb" => "# Prism::SingletonClassNode is mentioned here only\n",
          "plugins/p/lib/b.rb" => "when Prism::SingletonClassNode\n",
          "plugins/p/spec/c_spec.rb" => "when Prism::ModuleNode\n"
        }.each do |path, source|
          FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
          File.write(File.join(dir, path), source)
        end

        expect(dispatching(DeclarationFactSources.code_under(dir))).to eq(["lib/a.rb", "plugins/p/lib/b.rb"])
      end
    end

    it "fails on an entry whose helper the file does not use" do
      entry = { "computes" => "something", "helpers" => ["ModuleFunctionState"] }

      expect(entry_problems("lib/a.rb", entry, "Prism::ClassNode"))
        .to eq(["lib/a.rb: lists ModuleFunctionState but never names ModuleFunctionState"])
    end
  end
end
