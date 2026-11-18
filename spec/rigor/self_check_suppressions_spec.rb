# frozen_string_literal: true

require "prism"
require "rigor"
require "rigor/analysis/runner"
require "tmpdir"
require "yaml"

# Every in-source suppression marker under `lib/` is a row of `rows` below, and every row still hides a finding.
# Rigor has no unused-suppression diagnostic, so this spec is that check for Rigor's own source:
#
# - the markers (Prism comments that open with `rigor:disable`, the shape the engine honours; prose and strings
#   that merely quote one are not markers) must be exactly the rows, matched by file, line and rule;
# - for each row, the marker is stripped from a copy of the file, the copy is analysed alone under the
#   self-check's own configuration (`.rigor.dist.yml`), and the finding it hid must come back on the marked line.
#
# A row names its reason: `issue:` for an engine defect (the row goes when the fix lands, and the second example
# fails to say so) or `permanent:` for a finding that is correct but deliberately accepted.
RSpec.describe "Inline suppressions in the self-check" do
  def self.rows
    rbs3_resolver = "rbs 3.x's `TypeNameResolver.new` takes the environment; the bundled rbs 4.x signature " \
                    "(`new(all_names, aliases)`) does not describe it. Kept while the gemspec allows rbs 3.x."
    [
      {
        path: "lib/rigor/environment/deferred_signature_plan.rb",
        anchor: "klass.new(env)",
        rule: "call.wrong-arity",
        permanent: rbs3_resolver
      },
      {
        path: "lib/rigor/environment/rbs_loader.rb",
        anchor: "klass.new(environment)",
        rule: "call.wrong-arity",
        permanent: rbs3_resolver
      }
    ]
  end

  def rows = self.class.rows

  def rows_path = "spec/rigor/self_check_suppressions_spec.rb"

  def marker_pattern = /\A#\s*rigor:disable(?:-file)?(?![\w-])\s*(?<rules>.*)/

  def repo_root
    File.expand_path("../..", __dir__)
  end

  def self_check_configuration
    data = YAML.safe_load_file(File.join(repo_root, ".rigor.dist.yml"))
    data.delete("cache")
    Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge(data, "paths" => ["lib"]))
  end

  def marked_line(row)
    lines = File.readlines(File.join(repo_root, row[:path]))
    lines.index { |text| text.include?(row[:anchor]) && text.include?("# rigor:disable #{row[:rule]}") }
  end

  it "has a row for every suppression marker under lib/, and a marker for every row" do
    found = Dir.glob(File.join(repo_root, "lib/**/*.rb")).flat_map do |file|
      relative = file.delete_prefix("#{repo_root}/")
      Prism.parse_file(file).comments.filter_map do |comment|
        match = marker_pattern.match(comment.location.slice)
        match && [relative, comment.location.start_line, match[:rules].strip]
      end
    end
    tabled = rows.map { |row| [row[:path], marked_line(row)&.+(1), row[:rule]] }

    expect(found).to match_array(tabled),
                     "the `# rigor:disable` markers under lib/ and the entries of `rows` in #{rows_path} differ. " \
                     "A new marker needs an entry naming its issue or a permanent reason, and the finding must " \
                     "still fire without it; an entry whose marker is gone is deleted from `rows`."
  end

  rows.each do |row|
    it "#{row[:path]} still needs its `#{row[:rule]}` suppression (#{row[:issue] || 'permanent'})" do
      reason = row[:issue] || "permanent"
      marker = " # rigor:disable #{row[:rule]}"
      line = marked_line(row)
      expect(line).not_to be_nil, "#{row[:path]} has no line with `#{row[:anchor]}` and `#{marker.strip}`"

      lines = File.readlines(File.join(repo_root, row[:path]))
      lines[line] = lines[line].sub(marker, "")
      configuration = self_check_configuration
      hidden = Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", File.basename(row[:path])), lines.join)
        Dir.chdir(dir) do
          runner = Rigor::Analysis::Runner.new(configuration: configuration)
          guarded_run(runner, ["lib"]).diagnostics.select { |d| d.rule == row[:rule] && d.line == line + 1 }
        end
      end

      expect(hidden).not_to be_empty,
                            "the `#{row[:rule]}` finding at #{row[:path]}:#{line + 1} no longer fires " \
                            "(#{reason}): delete three things — the `# rigor:disable #{row[:rule]}` marker on " \
                            "that line, the comment above it that explains it, and its entry in `rows` in " \
                            "#{rows_path}"
    end
  end
end
