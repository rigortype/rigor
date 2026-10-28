# frozen_string_literal: true

require "spec_helper"

# Issues #2079 and #2170 — the class-ivar census joins the writes another file's reopening makes, and those of the
# modules and superclasses on the class's chain, into the ivars it already holds. Each fixture directory is analysed
# as one project; a line marked `# FIRES <rule>` must report that rule and every other line must stay quiet. The
# fixtures carry Ruby 4.0.5's results in their comments.
RSpec.describe "cross-file and chain ivar census (#2079, #2170)", type: :runner do
  def fixture_files(fixture)
    Dir[File.join(__dir__, "fixtures/cross_file_ivar_census", fixture, "*.rb")]
      .to_h { |path| [File.basename(path), File.read(path)] }
  end

  def reported(result)
    result.diagnostics.reject { |d| d.severity == :info || d.rule.to_s == "call.unresolved-toplevel" }
          .map { |d| [File.basename(d.path), d.line, d.rule.to_s] }.sort
  end

  def marked(files)
    files.flat_map do |name, source|
      source.lines.each_with_index.filter_map do |line, index|
        rule = line[/# FIRES (\S+)/, 1]
        [name, index + 1, rule] if rule
      end
    end.sort
  end

  %w[reopening mixins cross_file_mixins mutation].each do |fixture|
    it "reports exactly the marked lines in #{fixture}/" do
      files = fixture_files(fixture)
      expect(reported(analyze(files: files))).to eq(marked(files))
    end
  end
end
