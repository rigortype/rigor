# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"
require "fileutils"

# Issue #1768 — the ADR-58 class-ivar census (`ScopeIndexer#build_class_ivar_index`) skipped writes made inside a
# `define_method` block, so an ivar `initialize` sets to `nil` and a `define_method` block sets to a String read as
# `nil` in a sibling `def`, and `@x.upcase` there reported a call on nil. A literal `define_method` block on the
# implicit or `self` receiver runs on the instance, so its writes now join the class's census as a `def` body's do.
RSpec.describe "the ADR-58 ivar census counts define_method block writes" do
  def census(source, class_name = "Box", ivar = :@x)
    program = Prism.parse(source).value
    index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    index[program].class_ivars_for(class_name)[ivar]&.describe
  end

  def box(body)
    "class Box\n  def initialize\n    @x = nil\n  end\n#{body.gsub(/^/, '  ')}\nend\n"
  end

  def diagnostics_for(files)
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      files.each { |name, source| File.write(File.join(lib, name), source) }
      runner = Rigor::Analysis::Runner.new(
        configuration: Rigor::Configuration.new("paths" => [lib]),
        cache_store: nil
      )
      guarded_run(runner).diagnostics
                         .reject { |d| d.path.to_s.end_with?(".rigor.yml") }
                         .map { |d| [File.basename(d.path.to_s), d.line, d.rule] }
    end
  end

  describe "instance-side define_method blocks" do
    {
      "a brace block (the issue)" => %(define_method(:set) { @x = "a" }),
      "a do block" => %(define_method(:set) do\n  @x = "a"\nend),
      "an explicit self receiver" => %(self.define_method(:set) { @x = "a" }),
      "a block nested in an iterator" => %(%i[a b].each { |n| define_method(n) { @x = "a" } }),
      "a conditional define_method" => %(if ENV["X"]\n  define_method(:set) { @x = "a" }\nend),
      "a define_method in a class method body" => %(def self.make\n  define_method(:set) { @x = "a" }\nend)
    }.each do |shape, body|
      it "joins the write in #{shape}" do
        expect(census(box(body))).to eq(%("a"?))
      end
    end

    it "joins a define_method block in a class_eval block on the class" do
      source = "#{box('')}Box.class_eval { define_method(:set) { @x = \"a\" } }\n"
      expect(census(source)).to eq(%("a"?))
    end

    # A define_method block is a method body, not class-body code: its write does not exempt the ivar from the
    # read-before-write `nil` a sibling def's read contributes.
    it "keeps the read-before-write nil for an ivar only a define_method block writes" do
      source = %(class W\n  define_method(:set) { @x = "a" }\n  def get = @x\nend\n)
      expect(census(source, "W")).to eq(%("a"?))
    end

    it "keeps it for a define_method block in an included block" do
      source = %(module M\n  included do\n    define_method(:arm!) { @x = :yes }\n  end\n  def armed? = @x\nend\n)
      expect(census(source, "M")).to eq(":yes?")
    end

    # A class-body write is the class object's ivar: it does not exempt an ivar a define_method block writes from
    # the read-before-write `nil`, while a def-only writer keeps the exemption it has on master.
    it "keeps the read-before-write nil when the class body writes the ivar too" do
      source = %(class W\n  @x = nil\n  define_method(:set) { @x = "a" }\n  def get = @x\nend\n)
      expect(census(source, "W")).to eq(%("a"?))
      expect(census(source.sub(%(define_method(:set) { @x = "a" }), %(def set = (@x = "a"))), "W")).to eq(%("a"))
    end

    it "keeps the read-before-write nil for an op-write in the block beside a class-body write" do
      source = %(class OpW\n  @n = 0\n  define_method(:inc) { @n += 1 }\n  def get = (@n ? 1 : 2)\nend\n)
      expect(census(source, "OpW", :@n)).to eq("Integer?")
      expect(diagnostics_for("opw.rb" => source)).to be_empty
    end

    it "keeps a define_method call's own argument write a class-body write" do
      source = %(class W\n  define_method((@n = :m)) { @x = "a" }\n  def set = (@n = :k)\n  def get = @n\nend\n)
      expect(census(source, "W", :@n)).to eq(":k")
    end

    it "types the block's rvalue on the instance side" do
      expect(census(box(%(define_method(:set) { @x = self })))).to eq("Box?")
    end
  end

  describe "writes that do not reach an instance" do
    {
      "a define_method with a lambda argument" => %(define_method(:set, -> { @x = "a" })),
      "a define_method with a block-pass lambda" => %(define_method(:set, &-> { @x = "a" })),
      "a define_method reusing an UnboundMethod" => %(define_method(:other, instance_method(:initialize))),
      "a class_eval block in the class body" => %(class_eval { @x = "a" }),
      "a singleton_class.define_method block" => %(singleton_class.define_method(:set) { @x = "a" }),
      "a define_singleton_method block" => %(define_singleton_method(:set) { @x = "a" }),
      "a define_method in a class << self body" => %(class << self\n  define_method(:set) { @x = "a" }\nend),
      "a define_method in a singleton_class.class_eval block" =>
        %(singleton_class.class_eval do\n  define_method(:set) { @x = "a" }\nend),
      "a define_method on another receiver" => %(Other.define_method(:set) { @x = "a" }),
      "an anonymous Class.new body" => %(Class.new { define_method(:set) { @x = "a" } }),
      "a named Class.new body" => %(K = Class.new { define_method(:set) { @x = "a" } }),
      "an ordinary block in the class body" => %(tap { @x = "a" })
    }.each do |shape, body|
      it "leaves the census alone for #{shape}" do
        expect(census(box(body))).to eq("nil")
      end
    end

    # Ruby does install this block as Box's instance method, so this is a false positive (#2167). The census counts
    # exactly the blocks whose `self` `DefineMethodBlockSelf` narrows, and that match is a literal `define_method`
    # (#963). Flip this when #2167 is fixed.
    it "does not count a send(:define_method) block" do
      expect(census(box(%(send(:define_method, :set) { @x = "a" })))).to eq("nil")
    end

    # Ruby writes these on another object, so `@x` stays nil on Box's instance; the census still counts them, which
    # widens the type and only misses a report (#2166). Flip this when #2166 is fixed.
    {
      "an instance_exec on another object" => %(Object.new.instance_exec { @x = "a" }),
      "a Class.new body" => %(Class.new { @x = "a" }),
      "a Struct.new block" => %(Struct.new(:a) { @x = "a" }),
      "a Data.define block" => %(Data.define(:a) { @x = "a" })
    }.each do |shape, inner|
      it "still counts a write in #{shape} inside a define_method block" do
        expect(census(box(%(define_method(:set) { #{inner} })))).to eq(%("a"?))
      end
    end

    it "records no ownerless census entry for a class << self or anonymous Class.new body" do
      source = box(%(class << self\n  define_method(:a) { @x = "a" }\nend\n) +
                   %(Class.new { define_method(:b) { @x = "b" } }))
      program = Prism.parse(source).value
      index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
      expect(index[program].class_ivars.keys).to eq(["Box"])
    end

    it "credits a named Class.new body's define_method to that class" do
      source = box(%(K = Class.new { define_method(:set) { @x = "a" } }))
      expect(census(source, "Box::K")).to eq(%("a"))
    end
  end

  describe "rigor check" do
    it "keeps a sibling def's read quiet (the issue)" do
      expect(diagnostics_for("box.rb" => box(%(define_method(:set) { @x = "a" }\ndef get = @x.upcase)))).to be_empty
    end

    it "does not fold a writer-only ivar's truthiness in a sibling def" do
      source = <<~RUBY
        class Feature
          define_method(:enable!) { @enabled = true }
          define_method(:set) { @x = "a" }
          def status
            if @enabled then "on" else "off" end
          end
          def label = (@enabled ? "on" : "off")
          def get
            return "none" unless @x
            @x
          end
        end
      RUBY
      expect(diagnostics_for("feature.rb" => source)).to be_empty
    end

    it "does not fold it when the class body writes the ivar too" do
      source = <<~RUBY
        class Box
          @x = nil
          define_method(:set) { @x = "a" }
          def get = (@x ? 1 : 2)
        end

        class Cfg
          @enabled = false
          define_method(:enable!) { @enabled = true }
          def on?
            return false unless @enabled
            true
          end
        end
      RUBY
      expect(diagnostics_for("box.rb" => source)).to be_empty
    end

    it "still folds a flow-live write in a def beside the block (the control)" do
      source = <<~RUBY
        class Feature
          define_method(:enable!) { @enabled = true }
          def status
            @enabled = true
            if @enabled then "on" else "off" end
          end
        end
      RUBY
      expect(diagnostics_for("feature.rb" => source)).to eq([["feature.rb", 5, "flow.always-truthy-condition"]])
    end

    it "does not have sig-gen write a non-nil return for a writer-only ivar" do
      Dir.mktmpdir do |dir|
        lib = File.join(dir, "lib")
        FileUtils.mkdir_p(lib)
        source = %(class Getter\n  define_method(:set) { @x = "a" }\n  def get = @x\nend\n)
        File.write(File.join(lib, "getter.rb"), source)
        configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("paths" => [lib]))
        candidates = Rigor::SigGen::Generator.new(configuration: configuration, paths: [lib]).run
        expect(candidates.find { |c| c.method_name == :get }.rbs).to eq(%(def get: () -> ("a" | nil)))
      end
    end

    it "still reports a def's read when only the class object's ivar is written" do
      expect(diagnostics_for("box.rb" => box(%(class_eval { @x = "a" }\ndef get = @x.upcase))))
        .to eq([["box.rb", 6, "call.undefined-method"]])
    end

    # The census is per file (as for `attr_writer`): a reopening's define_method feeds the reopening's own
    # census, exactly as a `def` written there does, and does not reach the first file's.
    it "credits a define_method in a reopening to that file's census, as a def there is" do
      first = box("def get = @x.upcase")
      with_block = "class Box\n  define_method(:set) { @x = \"a\" }\n  " \
                   "def clear = (@x = nil)\n  def get2 = @x.upcase\nend\n"
      with_def = with_block.sub(%(define_method(:set) { @x = "a" }), %(def set = (@x = "a")))

      expected = [["box.rb", 5, "call.undefined-method"]]
      expect(diagnostics_for("box.rb" => first, "reopen.rb" => with_def)).to eq(expected)
      expect(diagnostics_for("box.rb" => first, "reopen.rb" => with_block)).to eq(expected)
    end

    # #1695 left define_method blocks unseeded from the census; they still are, so the block's own read of an ivar
    # another block writes answers Dynamic rather than the census type.
    it "does not seed the define_method block itself from the census" do
      source = box(%(define_method(:set) { @x = "a" }\ndefine_method(:shout) { @x.no_such_method }))
      expect(diagnostics_for("box.rb" => source)).to be_empty
    end
  end
end
