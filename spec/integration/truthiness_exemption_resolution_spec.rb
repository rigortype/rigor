# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Issue #3437 — the truthiness withholding's local-declaration exemption matched a file's own constant by a suffix
# relation on qualified names, so a file that assigns `M::MODE` stopped withholding `flow.always-truthy-condition`
# on a top-level `MODE` it does not assign. The exemption now matches the names a reference can resolve to where it
# is written: behind each `Module.nesting` entry, behind each ancestor of the enclosing class, and at the top level.
#
# `a.rb` publishes the top-level constants every reader below could mistake for its own. Each example pairs the
# reads that must stay withheld with reads of the file's own constant that must keep firing, so neither an exemption
# that never holds nor one that always holds passes.
RSpec.describe "the truthiness exemption's constant resolution" do
  let(:published) { "MODE = :production\nLIMIT = 5\n" }

  # The `flow.always-truthy-condition` lines of `c.rb`, analysed beside `a.rb` and any `others` (`{"b.rb" => src}`).
  def firing_lines(reader, others = {})
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "a.rb"), published)
      others.each { |name, source| File.write(File.join(lib, name), source) }
      File.write(File.join(lib, "c.rb"), reader)
      configuration = Rigor::Configuration.new("paths" => [lib])
      result = guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil))
      result.diagnostics.select { |d| d.qualified_rule == "flow.always-truthy-condition" }
            .select { |d| File.basename(d.path) == "c.rb" }.map(&:line).sort
    end
  end

  it "withholds on the issue's repro, a top-level read in a file that assigns only `M::MODE`" do
    expect(firing_lines(<<~RUBY)).to eq([])
      module M; MODE = [2]; end

      if MODE == :production; puts 1; end
    RUBY
  end

  it "keeps firing on the file's own `M::MODE` read inside `module M`" do
    expect(firing_lines(<<~RUBY)).to eq([4, 6])
      module M
        MODE = :local

        puts 1 if MODE == :local

        def self.check = MODE == :local ? "y" : "n"
      end
    RUBY
  end

  it "follows `Module.nesting`: an enclosing module is a rung, a compact header's namespace is not" do
    # Line 5 is `M::N` written nested, whose nesting holds `M`, so `MODE` is this file's `M::MODE`. Line 10 is the
    # same module written compact, whose nesting is `[M::N]` alone, and line 14 an unrelated module: both read the
    # top-level `MODE` of `a.rb`.
    expect(firing_lines(<<~RUBY)).to eq([5])
      module M
        MODE = :local

        module N
          def self.nested = MODE == :local ? "y" : "n"
        end
      end

      module M::N
        def self.compact = MODE == :production ? "y" : "n"
      end

      module Other
        def self.unrelated = MODE == :production ? "y" : "n"
      end
    RUBY
  end

  it "reads a leading `::` as the top level alone" do
    # Inside `module M` a bare `MODE` is the file's own (line 4), and `::MODE` is `a.rb`'s (lines 5 and 8).
    expect(firing_lines(<<~RUBY)).to eq([4])
      module M
        MODE = :local

        def self.own = MODE == :local ? "y" : "n"
        def self.rooted = ::MODE == :production ? "y" : "n"
      end

      puts 1 if ::MODE == :production
    RUBY
  end

  it "keeps firing on a constant the enclosing class inherits from a class this file declares" do
    # Ruby reads the ancestors after the lexical scope and before the top level, so `MODE` inside `Sub` is
    # `Base::MODE` (line 6). `Other` inherits nothing and reads `a.rb`'s (line 10).
    expect(firing_lines(<<~RUBY)).to eq([6])
      class Base
        MODE = :local
      end

      class Sub < Base
        def check = MODE == :local ? "y" : "n"
      end

      class Other
        def check = MODE == :production ? "y" : "n"
      end
    RUBY
  end

  it "asks the one interprocedural hop under the callee's nesting, not the caller's" do
    # `AppConfig.production?` is called from the top level and reads `MODE` inside `module AppConfig`, the file's
    # own (line 8). The top-level `prod?` reads `a.rb`'s `MODE`, which `AppConfig::MODE` does not shadow (line 9).
    expect(firing_lines(<<~RUBY)).to eq([8])
      module AppConfig
        MODE = :local

        def self.production? = MODE == :local
      end

      def prod? = MODE == :production
      puts 1 if AppConfig.production?
      puts 2 if prod?
    RUBY
  end

  it "asks a singleton hop's body with the receiver as `self`, so the receiver's ancestors are rungs" do
    # `Sub.chk?` is called from the top level and reads `LIMIT` in `class Sub < Base`, which is the file's own
    # `Base::LIMIT` (line 5): the caller's top-level `self` has no ancestors to reach `Base` through.
    expect(firing_lines(<<~RUBY)).to eq([5])
      class Base; LIMIT = 9; end
      class Sub < Base
        def self.chk? = LIMIT == 9
      end
      puts 1 if Sub.chk?
    RUBY
  end

  it "finds an implicit-self callee in a class on the class's ancestors, then at the top level" do
    # `b.rb`'s top-level `prod?` and `Helpers#prod_too?` read `a.rb`'s `MODE`. Reached from inside a class,
    # directly (line 9) or through an ivar seed (lines 15 and 16), each stays withheld. `Own#big?` reads the
    # file's own `Own::LIMIT` and keeps firing through the included module (line 20). `Shared#big_too?` is asked
    # with `Shared` as `self`, not the caller `Sub`: its `LIMIT` is `a.rb`'s, which `Base::LIMIT` does not shadow
    # from inside `Shared`, so line 28 stays withheld.
    expect(firing_lines(<<~RUBY, "b.rb" => "def prod? = MODE == :production\n")).to eq([20])
      module Helpers
        def prod_too? = MODE == :production
      end
      module Own
        LIMIT = 9
        def big? = LIMIT == 9
      end
      class K
        def chk = prod? ? 1 : 2
      end
      class J
        include Helpers
        def initialize = (@p = prod?; @q = prod_too?)

        def chk = @p ? 1 : 2
        def chk_too = @q ? 1 : 2
      end
      class L
        include Own
        def chk = big? ? 1 : 2
      end
      module Shared
        def big_too? = LIMIT == 5
      end
      class Base; LIMIT = 9; end
      class Sub < Base
        include Shared
        def chk = big_too? ? 1 : 2
      end
    RUBY
  end

  it "resolves an alias's source where the alias is written" do
    # `M::OWN` copies the file's own `M::MODE` and stays reportable (line 9). `M::ROOTED` and the top-level
    # `FOREIGN` copy `a.rb`'s `MODE`, which the file's `M::MODE` does not make its own (lines 10 and 11).
    expect(firing_lines(<<~RUBY)).to eq([9])
      module M
        MODE = :local
        OWN = MODE
        ROOTED = ::MODE
      end

      FOREIGN = MODE

      puts 1 if M::OWN == :local
      puts 2 if M::ROOTED == :production
      puts 3 if FOREIGN == :production
    RUBY
  end

  it "resolves a constant copied into an instance variable under the class's nesting" do
    # `M::Holder` seeds `@limit` from the file's own `M::LIMIT` (line 9); the top-level `Reader` seeds it from
    # `a.rb`'s `LIMIT` (line 18).
    expect(firing_lines(<<~RUBY)).to eq([9])
      module M
        LIMIT = 9

        class Holder
          def initialize
            @limit = LIMIT
          end

          def big? = @limit == 9 ? "y" : "n"
        end
      end

      class Reader
        def initialize
          @limit = LIMIT
        end

        def big? = @limit == 5 ? "y" : "n"
      end
    RUBY
  end
end
