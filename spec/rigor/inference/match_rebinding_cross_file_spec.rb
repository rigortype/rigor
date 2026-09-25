# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #1364 — an implicit-self call keeps the match-global narrowing only in a frame that hands its slot to no code
# the analyzer cannot trace. A Regexp constant defined in another file does not resolve (#1373), so the broad reading
# of the frame's blocks counts an unresolved constant as a possible Regexp: the implicit-self call then forgets as it
# did before, and the read below it is `String?`. Ruby answers nil for each positive (`cross_case("ab=zz")`, the
# others with `line = "ab=c"`), and "ab" for the two controls.
RSpec.describe "match-global narrowing across files" do
  let(:patterns) do
    <<~RUBY
      # frozen_string_literal: true

      module Patterns
        KEYWORD = /(\\w+)!/
        ALL = [/(\\w+)!/, /(\\w+)\\?/].freeze
        TAG = :tag
      end
    RUBY
  end

  let(:reader) do
    <<~'RUBY'
      def each_token(s) = s.split(",").each { |t| yield t }
      def keep(&blk) = @kept = blk
      def run_kept(*args) = @kept.call(*args)
      def helper(&) = yield("q")

      def cross_case(line)
        if line =~ /^(\w+)=(.*)$/
          each_token($2) { |tok| case tok when Patterns::KEYWORD then tok end }
          Rigor.dump_type($1)
        end
      end

      def cross_index(line)
        if line =~ /^(\w+)=/
          helper { |l| l.index(Patterns::KEYWORD) }
          Rigor.dump_type($1)
        end
      end

      def cross_stored(line)
        keep { |l| l[Patterns::KEYWORD] }
        if line =~ /^(\w+)=/
          run_kept("q")
          Rigor.dump_type($1)
        end
      end

      def cross_splat(line)
        keep { |l| case l when *Patterns::ALL then l end }
        if line =~ /^(\w+)=/
          run_kept("q")
          Rigor.dump_type($1)
        end
      end

      def cross_symbol_constant(line)
        helper { |l| case l when Patterns::TAG then l end }
        if line =~ /^(\w+)=/
          helper { |l| l.upcase }
          Rigor.dump_type($1)
        end
      end

      def plain(line)
        if line =~ /^(\w+)=/
          helper { |l| l.upcase }
          Rigor.dump_type($1)
        end
      end
    RUBY
  end

  def dumps
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "patterns.rb"), patterns)
      File.write(File.join(lib, "reader.rb"), reader)
      runner = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new("paths" => [lib]), cache_store: nil
      )
      guarded_run(runner).diagnostics
                         .select { |d| d.qualified_rule == "dump.type" }
                         .sort_by(&:line)
                         .map { |d| d.message.delete_prefix("dump_type: ") }
    end
  end

  it "forgets at an implicit-self call in a frame whose block matches through another file's constant" do
    expect(dumps).to eq(%w[String? String? String? String? String String])
  end
end
