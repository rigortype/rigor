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
      source = box("") + %(Box.class_eval { define_method(:set) { @x = "a" } }\n)
      expect(census(source)).to eq(%("a"?))
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
      "an anonymous Class.new body" => %(Class.new { define_method(:set) { @x = "a" } }),
      "a named Class.new body" => %(K = Class.new { define_method(:set) { @x = "a" } }),
      "an ordinary block in the class body" => %(tap { @x = "a" })
    }.each do |shape, body|
      it "leaves the census alone for #{shape}" do
        expect(census(box(body))).to eq("nil")
      end
    end

    it "records no ownerless census entry for a class << self or anonymous Class.new body" do
      source = box(%(class << self\n  define_method(:a) { @x = "a" }\nend\nClass.new { define_method(:b) { @x = "b" } }))
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

    it "keeps a sibling def's read quiet (the issue)" do
      expect(diagnostics_for("box.rb" => box(%(define_method(:set) { @x = "a" }\ndef get = @x.upcase)))).to be_empty
    end

    it "still reports a def's read when only the class object's ivar is written" do
      expect(diagnostics_for("box.rb" => box(%(class_eval { @x = "a" }\ndef get = @x.upcase))))
        .to eq([["box.rb", 6, "call.undefined-method"]])
    end

    # The census is per file (as for `attr_writer`): a reopening's define_method feeds the reopening's own
    # census, exactly as a `def` written there does, and does not reach the first file's.
    it "credits a define_method in a reopening to that file's census, as a def there is" do
      first = box("def get = @x.upcase")
      with_block = "class Box\n  define_method(:set) { @x = \"a\" }\n  def clear = (@x = nil)\n  def get2 = @x.upcase\nend\n"
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
