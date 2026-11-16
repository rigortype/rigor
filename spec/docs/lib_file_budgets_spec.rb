# frozen_string_literal: true

# Gate the line budget of every `lib/` Ruby file of 1,000 or more lines (ADR-116 WD0, #1192), in the
# shape ADR-97's `agent_index_spec.rb` budgets use: a checked-in number per file, a failure that says
# what to do, and examples that pin the validator on synthetic input so the gate is proven to fail.
#
# The data is `spec/docs/lib_file_budgets.yml`, one `<path>: <budget>` row per file. The rule:
#
#   - a budget is a multiple of 100 (`LibFileBudgets::STEP`);
#   - a file's line count (`wc -l`, physical lines, not code lines) is at most its budget;
#   - and the budget is less than 200 above the count (`LibFileBudgets::SLACK`).
#
# So a row may sit anywhere from the count up to 199 lines above it. The initial rows are the smallest
# multiple of 100 that holds each file, but the gate accepts any multiple in that range: growth of up to
# 99 lines right after a row is set is not gated, and a shrink leaves its row up to 199 lines high until
# the row is lowered.
#
# Why a bucket, not the exact count: about 15 PRs a day merge to `master`, and 44% of `lib/`-touching
# PRs touch one of the three largest files. An exact budget would make every pair of in-flight PRs on
# one file edit the same row, and conflict there, even when neither grows the file past its limit. A
# bucket moves a row only when a file crosses a boundary, so most concurrent edits leave it alone. The
# decision and its alternatives are in `approval-queue.d/`.
#
# The gate fails when:
#
#   - a budgeted file has more lines than its budget (growth needs a module with a named interface,
#     ADR-116 C3, or a raised budget in the same PR, reviewed);
#   - a budget is 200 or more above its file (a split must lower its row);
#   - a `lib/` file of 1,000+ lines has no row (a new large file is a decision);
#   - a row names a file that is not a tracked file under `lib/`, or one under 1,000 lines;
#   - a budget is not a multiple of 100;
#   - the same path has two rows (YAML keeps the last one silently, so the first would be ignored).
#
# Membership comes from the index (`TrackedFiles`, see its header): a glob would also read an untracked
# scratch file in a contributor's clone that CI never sees. Content comes from the working tree, which
# is the point of a pre-push run.
#
# The inline `Metrics/ClassLength` and `Metrics/ModuleLength` disables stay where they are; this gate
# is the control on file size, and it does not replace them.

require "spec_helper"
require "yaml"

module LibFileBudgets
  ROOT = File.expand_path("../..", __dir__)
  DATA = File.expand_path("lib_file_budgets.yml", __dir__)
  DATA_NAME = "spec/docs/lib_file_budgets.yml"
  FLOOR = 1000
  STEP = 100
  SLACK = 200

  module_function

  # The physical line count `wc -l` reports (newline bytes), read as bytes so an odd encoding cannot
  # raise while counting.
  def line_count(path)
    File.binread(path).count("\n")
  end

  # `path => line count` for every tracked `lib/**/*.rb` file that exists in the working tree.
  def corpus(root: ROOT)
    TrackedFiles.call(root, "lib")
                .select { |path| path.end_with?(".rb") }
                .map { |path| path.dup.force_encoding(Encoding::UTF_8) }
                .select { |path| File.file?(File.join(root, path)) }
                .to_h { |path| [path, line_count(File.join(root, path))] }
  end

  def rows(data: DATA)
    loaded = YAML.safe_load_file(data)
    raise "#{data} must be a mapping of path to budget" unless loaded.is_a?(Hash)

    loaded
  end

  # One message per path that has more than one row. `YAML.safe_load_file` keeps the last value for a
  # repeated key without a word, so the duplicate is read from the document's own key nodes instead.
  def duplicate_rows(data: DATA)
    keys = YAML.parse_file(data).root.children.each_slice(2).map { |key, _value| key.value }
    keys.tally.select { |_path, count| count > 1 }.map do |path, count|
      "#{DATA_NAME}: row `#{path}` appears #{count} times. YAML keeps only the last value, so the " \
        "budget is ambiguous. Keep one row."
    end
  end

  # Every problem with `rows` against `counts`, one message each. `counts` maps each tracked `lib/`
  # Ruby file that exists to its line count; `rows` maps a path to its budget.
  def offenses(rows:, counts:)
    found = rows.filter_map { |path, budget| row_offense(path, budget, counts[path]) }
    counts.each do |path, lines|
      next if lines < FLOOR || rows.key?(path)

      found << missing_row(path, lines)
    end
    found
  end

  def row_offense(path, budget, lines)
    if lines.nil?
      "#{DATA_NAME}: row `#{path}` names a file that is not a tracked file under lib/. A deleted or " \
        "renamed file takes its row with it: remove the row, or fix its path."
    elsif !budget.is_a?(Integer) || (budget % STEP).nonzero?
      "#{DATA_NAME}: the budget for #{path} is #{budget.inspect}, not a multiple of #{STEP}. Use the " \
        "smallest multiple of #{STEP} that holds the file (#{round_up(lines)})."
    elsif lines < FLOOR
      "#{DATA_NAME}: #{path} is #{lines} lines, under the #{FLOOR}-line floor, so it needs no row. " \
        "Remove its row."
    elsif lines > budget
      "#{path} is #{lines} lines, over its budget of #{budget}. Either move the new code into its own " \
        "module with a named interface (ADR-116 C3), or raise this row in #{DATA_NAME} to " \
        "#{round_up(lines)} (the smallest multiple of #{STEP} that holds the file) in this PR and say " \
        "why in its body."
    elsif budget - lines >= SLACK
      "#{path} is #{lines} lines against a budget of #{budget}: the budget is #{budget - lines} above the " \
        "file. A split must lower its row. Set it to #{round_up(lines)} (the smallest multiple of " \
        "#{STEP} that holds the file)."
    end
  end

  def missing_row(path, lines)
    "#{path} is #{lines} lines (#{FLOOR}+) and has no row in #{DATA_NAME}. Add `#{path}: " \
      "#{round_up(lines)}` (the smallest multiple of #{STEP} that holds the file)."
  end

  def round_up(lines)
    ((lines + STEP - 1) / STEP) * STEP
  end
end

RSpec.describe "lib/ file-size budgets (ADR-116 WD0, #1192)" do
  it "reads a non-empty corpus and a non-empty budget file" do
    # Non-vacuity: a corpus or data file that reads as empty would pass every check below.
    expect(LibFileBudgets.corpus.count { |_path, lines| lines >= LibFileBudgets::FLOOR }).to be > 0
    expect(LibFileBudgets.rows).not_to be_empty
  end

  it "keeps every budgeted file within its budget, with less than #{LibFileBudgets::SLACK} of slack" do
    problems = LibFileBudgets.offenses(rows: LibFileBudgets.rows, counts: LibFileBudgets.corpus)

    expect(problems).to be_empty, problems.join("\n")
  end

  it "has no path with two rows in the checked-in budget file" do
    expect(LibFileBudgets.duplicate_rows).to be_empty
  end

  describe "the validator" do
    let(:file) { "lib/rigor/example.rb" }

    def problems(rows, counts)
      LibFileBudgets.offenses(rows: rows, counts: counts)
    end

    # The one message `rows` against `counts` produces; any other count fails the example.
    def only_problem(rows, counts)
      found = problems(rows, counts)
      expect(found.size).to eq(1)
      found.first
    end

    it "accepts a file at its budget, or up to 199 lines under it" do
      expect(problems({ file => 1100 }, { file => 1100 })).to be_empty
      expect(problems({ file => 1300 }, { file => 1101 })).to be_empty
    end

    it "fails growth past the budget, and says to split or raise to the smallest bucket that holds it" do
      message = only_problem({ file => 1100 }, { file => 1101 })

      expect(message).to include("#{file} is 1101 lines, over its budget of 1100")
      expect(message).to include("ADR-116 C3")
      expect(message).to include("to 1200 (the smallest multiple of 100 that holds the file)")
    end

    it "names the smallest bucket that holds a file that grew by more than one step" do
      message = only_problem({ file => 1100 }, { file => 1350 })

      expect(message).to include("over its budget of 1100")
      expect(message).to include("to 1400 (the smallest multiple of 100 that holds the file)")
    end

    it "fails a budget 200 or more above its file, and says a split lowers it" do
      message = only_problem({ file => 1300 }, { file => 1100 })

      expect(message).to include("the budget is 200 above the file")
      expect(message).to include("Set it to 1100")
    end

    it "fails a 1,000+ line file with no row, and names the row to add" do
      message = only_problem({}, { file => 1050 })

      expect(message).to include("#{file} is 1050 lines (1000+) and has no row")
      expect(message).to include("`#{file}: 1100`")
    end

    it "requires a row for a file of exactly the floor" do
      expect(only_problem({}, { file => 1000 })).to include("1000 lines (1000+) and has no row")
    end

    it "accepts a row for a file of exactly the floor" do
      expect(problems({ file => 1000 }, { file => 1000 })).to be_empty
    end

    it "does not require a row for a file under the floor" do
      expect(problems({}, { file => 999 })).to be_empty
    end

    it "fails a row that names a file that is not tracked under lib/" do
      expect(only_problem({ file => 1100 }, {})).to include("names a file that is not a tracked file")
    end

    it "fails a row for a file under the floor, and says to remove it" do
      expect(only_problem({ file => 1100 }, { file => 999 })).to include("under the 1000-line floor")
    end

    it "fails a budget that is not a multiple of 100" do
      expect(only_problem({ file => 1150 }, { file => 1100 })).to include("not a multiple of 100")
    end

    it "names a path that appears in two rows of the budget file" do
      Dir.mktmpdir do |dir|
        data = File.join(dir, "budgets.yml")
        File.write(data, "lib/rigor/example.rb: 1100\nlib/rigor/example.rb: 1200\n")

        found = LibFileBudgets.duplicate_rows(data: data)
        expect(found.size).to eq(1)
        expect(found.first).to include("row `lib/rigor/example.rb` appears 2 times")
      end
    end
  end
end
