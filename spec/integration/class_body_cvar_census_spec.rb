# frozen_string_literal: true

require "spec_helper"

# Issue #3204 — the class-cvar census read only `def` bodies, so a class-body or module-body `@@x = nil` never
# reached a sibling method's seed, and `@@x.nil?` there folded on correct code. Each "does not fold" source runs
# its `puts` under Ruby 4.0.5 (the guarded read happens before the `def` that writes the error); each "folds" one
# is a control whose read can never be `nil`.
module ClassBodyCvarCensusFixtures
  DIR = File.join(__dir__, "fixtures/class_body_cvar_census")
  # Each `# N: …` row of the fixture, keyed by its heading.
  ROWS = File.read(File.join(DIR, "unseen_writes.rb")).split(/^(?=# \d+: )/)
             .to_h { |row| [row.lines.first.delete_prefix("# ").strip, row] }.freeze
end

RSpec.describe "class-body cvar census (#3204)", type: :runner do
  def folds(source)
    analyze(files: { "code.rb" => source }).diagnostics
                                           .select { |d| d.rule.to_s == "flow.always-truthy-condition" }
                                           .map(&:line)
  end

  def reader(name)
    "  def failures\n    count = #{name}.nil? ? 0 : 1\n    puts \"clean\" if count == 0\n    count\n  end\n"
  end

  def guard_line(source) = source.lines.index { |l| l.include?("if count == 0") } + 1

  %w[class module].each do |keyword|
    it "does not fold a #{keyword}-body `@@x = nil` read in a sibling method" do
      source = "#{keyword} Klass\n  @@plain = nil\n  def set = @@plain = RuntimeError.new(\"x\")\n" \
               "#{reader('@@plain')}end\n"
      expect(folds(source)).to eq([])
    end

    it "folds a #{keyword}'s cvar only its `def`s write (control)" do
      source = "#{keyword} Klass\n  def set = @@plain = RuntimeError.new(\"x\")\n#{reader('@@plain')}end\n"
      expect(folds(source)).to eq([guard_line(source)])
    end
  end

  it "does not fold a `class << self` body's `@@x = nil`, which is the enclosing class's" do
    source = "class Sing\n  class << self\n    @@s = nil\n  end\n  def set = @@s = 1\n#{reader('@@s')}end\n"
    expect(folds(source)).to eq([])
  end

  it "does not fold a read in a `def` that precedes the class-body write" do
    source = "class Before\n#{reader('@@b')}  def set = @@b = 1\n  @@b = nil\nend\n"
    expect(folds(source)).to eq([])
  end

  it "does not fold a cvar the class body seeds with `class_variable_set`" do
    source = "class Cvs\n  class_variable_set(:@@x, nil)\n  def set = @@x = 1\n#{reader('@@x')}end\n"
    expect(folds(source)).to eq([])
  end

  it "folds when `class_variable_set` names another class (control)" do
    source = "class Other; end\nclass Cvs\n  Other.class_variable_set(:@@x, nil)\n  def set = @@x = 1\n" \
             "#{reader('@@x')}end\n"
    expect(folds(source)).to eq([guard_line(source)])
  end

  it "keeps a nested class's body write on the nested class" do
    # Ruby: `@@i = nil` in `Inner` is `Outer::Inner`'s cvar; `Outer`'s own `@@i` is only ever `2`.
    inner = "  class Inner\n    @@i = nil\n    def set = @@i = 1\n#{reader('@@i').gsub(/^/, '  ')}  end\n"
    source = "class Outer\n#{inner}  def set = @@i = 2\n#{reader('@@i')}end\n"
    outer_guard = source.lines.rindex { |l| l.include?("if count == 0") } + 1
    expect(folds(source)).to eq([outer_guard])
  end

  it "does not fold a subclass's read of a cvar only its superclass writes" do
    source = "class Base\n  @@c = nil\n  def set = @@c = 1\nend\nclass Sub < Base\n#{reader('@@c')}end\n"
    expect(folds(source)).to eq([])
  end

  # Round 1 of #3218's review: the census misses most of the other ways a cvar is written, so a class-body write
  # only joins an entry a `def` body's write creates, and a body-only seed stays unbound (`Dynamic[top]`). Every
  # row of the fixture runs clean under Ruby 4.0.5, and each reported `undefined method … for nil` or a fold
  # while a body-only `nil` seeded the read.
  describe "a class-body write joins, never creates" do
    def reported(files)
      diagnostics = analyze(files: files).diagnostics.reject { |d| d.severity == :info }
      diagnostics.map { |d| [File.basename(d.path), d.line, d.rule.to_s] }
    end

    ClassBodyCvarCensusFixtures::ROWS.each_key do |heading|
      it "reports nothing on a cvar the census cannot see written: #{heading}" do
        expect(reported("code.rb" => ClassBodyCvarCensusFixtures::ROWS.fetch(heading))).to eq([])
      end
    end

    it "reports nothing on a class reopened in another file" do
      files = %w[reopened_one.rb reopened_two.rb].to_h do |name|
        [name, File.read(File.join(ClassBodyCvarCensusFixtures::DIR, name))]
      end
      expect(reported(files)).to eq([])
    end

    it "still reads a `def`-only `nil` seed as `nil` (control)" do
      source = "class Pc\n  def self.reset = (@@x = nil)\n  def self.len = @@x.length\nend\n"
      expect(reported("code.rb" => source)).to eq([["code.rb", 3, "call.undefined-method"]])
    end
  end
end
