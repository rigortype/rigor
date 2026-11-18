# frozen_string_literal: true

require "rigor"
require "rigor/analysis/runner"
require "tmpdir"
require "yaml"

# Each inline `# rigor:disable` in `lib/` that covers an engine defect names its issue and is kept only while the
# row it hides still fires. Rigor has no unused-suppression diagnostic, so this spec is that check for the rows
# below: it strips the marker from a copy of the file, analyses the copy under the self-check's own
# configuration (`.rigor.dist.yml`) and expects the row back. When an example fails, the issues it names have
# been fixed (or the self-check's configuration no longer produces the row): delete the suppression and its
# comment from the file, and the row from this table.
RSpec.describe "Inline suppressions in the self-check" do
  def repo_root
    File.expand_path("../..", __dir__)
  end

  rows = [
    {
      path: "lib/rigor/analysis/require_relative_closure.rb",
      rule: "call.possible-nil-receiver",
      issues: "#3337 and #3338"
    }
  ]

  def self_check_configuration
    data = YAML.safe_load_file(File.join(repo_root, ".rigor.dist.yml"))
    data.delete("cache")
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data, "paths" => ["lib"]))
  end

  rows.each do |row|
    it "#{row[:path]} still needs its `#{row[:rule]}` suppression (#{row[:issues]})" do
      marker = " # rigor:disable #{row[:rule]}"
      lines = File.readlines(File.join(repo_root, row[:path]))
      line = lines.index { |text| text.include?(marker) }
      expect(line).not_to be_nil, "#{row[:path]} no longer carries `#{marker.strip}`: delete its row here"

      configuration = self_check_configuration
      rows_on_line = Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", File.basename(row[:path])), lines.join.sub(marker, ""))
        Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(configuration: configuration)
          guarded_run(runner, ["lib"]).diagnostics.select { |d| d.rule == row[:rule] && d.line == line + 1 }
        end
      end

      expect(rows_on_line).not_to be_empty,
                                  "the `#{row[:rule]}` row at #{row[:path]}:#{line + 1} no longer fires " \
                                  "(#{row[:issues]} landed?): delete the suppression, its comment and this row"
    end
  end
end
