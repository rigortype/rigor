# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Rigor::Environment::MissingGemConstantIndex do
  def write_gem(root, name, entry_relative, source)
    dir = File.join(root, name)
    path = File.join(dir, entry_relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
    dir
  end

  def build(gems, dirs)
    described_class.build(gems, spec_resolver: ->(name, _version) { dirs[name] })
  end

  it "maps a gem's top-level declarations to the gem, by reading — not by camelizing the gem name" do
    Dir.mktmpdir do |root|
      dirs = {
        "faraday" => write_gem(root, "faraday", "lib/faraday.rb", <<~RUBY),
          module Faraday
            class Connection
            end
          end
        RUBY
        # The declared constant does not match a camelization of the gem name — reading gets it right.
        "activesupport" => write_gem(root, "activesupport", "lib/activesupport.rb", <<~RUBY)
          module ActiveSupport
          end
          CoreExt = ActiveSupport
        RUBY
      }
      index = build([["faraday", "2.0.0"], ["activesupport", "7.0.0"]], dirs)

      expect(index).to eq(
        "Faraday" => "faraday",
        "ActiveSupport" => "activesupport",
        "CoreExt" => "activesupport"
      )
    end
  end

  it "roots a namespaced top-level declaration at its first segment" do
    Dir.mktmpdir do |root|
      dirs = { "money" => write_gem(root, "money", "lib/money.rb", "class Money::Error < StandardError; end\n") }
      expect(build([["money", "1.0.0"]], dirs)).to eq("Money" => "money")
    end
  end

  it "follows the dash -> directory entry-file convention" do
    Dir.mktmpdir do |root|
      dirs = {
        "rack-attack" => write_gem(root, "rack-attack", "lib/rack/attack.rb", "module Rack\nend\n")
      }
      expect(build([["rack-attack", "6.0.0"]], dirs)).to eq("Rack" => "rack-attack")
    end
  end

  it "fails open on a missing gem, a missing entry file, and an unparseable entry file" do
    Dir.mktmpdir do |root|
      dirs = {
        "no-entry" => write_gem(root, "no-entry", "lib/elsewhere.rb", "module NoEntry; end\n"),
        "broken" => write_gem(root, "broken", "lib/broken.rb", "class <%= oops %>\n")
      }
      index = build([["not-installed", "1.0.0"], ["no-entry", "1.0.0"], ["broken", "1.0.0"]], dirs)
      expect(index).to eq({})
    end
  end

  it "keeps the first gem on a top-level-constant collision" do
    Dir.mktmpdir do |root|
      dirs = {
        "aaa" => write_gem(root, "aaa", "lib/aaa.rb", "module Util; end\n"),
        "bbb" => write_gem(root, "bbb", "lib/bbb.rb", "module Util; end\n")
      }
      expect(build([["aaa", "1.0.0"], ["bbb", "1.0.0"]], dirs)).to eq("Util" => "aaa")
    end
  end
end
