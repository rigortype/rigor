# frozen_string_literal: true

require "rigor"
require "yaml"

# #3324 (variant B on #3353): the self-check proper reads `.rigor.dist.yml` with `parameter_inference: true`, and the
# consistency and precision gates read `.rigor.gates.yml`, which is the same configuration with the key off. This
# spec keeps the split from drifting:
#
# - the gates file differs from the dist file in that one key alone;
# - every command of the key-off targets and steps passes `--config .rigor.gates.yml` (`--config=` too, and on a
#   continuation line of the same command), and no command of the key-on targets passes `--config` at all;
# - the lists below are fixed and named, so every step of ci.yml's `acceptance-gates` job that runs rigor (a `run:`
#   naming `exe/rigor`, `make check*`, `make coverage`, or a `tool/*.rb` that drives the CLI or the runner) must be
#   in `ci_steps`. A NEW heavy step fails here, naming itself, until it is added on the side it belongs on.
RSpec.describe "The self-check's gates configuration" do
  def self.makefile_key_off = { "coverage" => 1, "coverage-tighten" => 1, "check-incremental" => 2 }
  def self.makefile_key_on = %w[check check-json check-plugins check-mutation-cache]

  # Each acceptance-gates step that runs rigor: the Makefile target it delegates to (whose side the lists above
  # assert), or `[:off, <number of rigor commands>]` for a step that runs rigor itself with the key off.
  def self.ci_steps
    {
      "Run precision coverage gate" => "make coverage",
      "Run plugin-contract check" => "make check-plugins",
      "Run incremental-analysis gate" => "make check-incremental",
      "Run mutation-cache gate" => "make check-mutation-cache",
      "Run the callee-floor memo audit" => [:off, 1],
      "Run the type_of shadow (advisory)" => [:off, 2]
    }
  end

  def repo_root
    File.expand_path("../..", __dir__)
  end

  def gates_flag = /--config[= ]\.rigor\.gates\.yml(\s|\z)/

  # Shell text split into commands, with backslash continuations joined, keeping those that run rigor.
  def rigor_commands(text)
    text.gsub(/\\\n\s*/, " ").lines.map(&:strip).select { |command| runs_rigor_command?(command) }
  end

  def runs_rigor_command?(command)
    return true if command.match?(%r{exe/rigor (check|coverage)})

    command.scan(%r{tool/\S+\.rb}).any? { |path| tool_runs_rigor?(path) }
  end

  def makefile_recipe(target)
    lines = File.readlines(File.join(repo_root, "Makefile"))
    start = lines.index { |line| line.start_with?("#{target}:") }
    raise "Makefile has no `#{target}:` target" if start.nil?

    lines[(start + 1)..].take_while { |line| line.start_with?("\t") }.map { |line| line.delete_prefix("\t") }.join
  end

  def acceptance_steps
    ci = YAML.safe_load_file(File.join(repo_root, ".github/workflows/ci.yml"))
    ci.dig("jobs", "acceptance-gates", "steps").select { |step| step["run"] }
  end

  def tool_runs_rigor?(path)
    full = File.join(repo_root, path)
    File.exist?(full) && File.read(full).match?(%r{exe/rigor|Rigor::CLI|Analysis::Runner})
  end

  def runs_rigor?(run)
    run.match?(%r{exe/rigor|\bmake (check\S*|coverage)\b}) ||
      run.scan(%r{tool/\S+\.rb}).any? { |path| tool_runs_rigor?(path) }
  end

  it "differs from .rigor.dist.yml only in parameter_inference, which it turns off" do
    raw = YAML.safe_load_file(File.join(repo_root, ".rigor.gates.yml"))
    expect(raw).to eq("includes" => [".rigor.dist.yml"], "parameter_inference" => false)

    dist = Rigor::Configuration.load(File.join(repo_root, ".rigor.dist.yml")).to_h
    gates = Rigor::Configuration.load(File.join(repo_root, ".rigor.gates.yml")).to_h
    expect(dist["parameter_inference"]).to be(true)
    # `config_path` names the file loaded, so it is the one other key that may differ.
    expect(gates.except("config_path")).to eq(dist.except("config_path").merge("parameter_inference" => false))
  end

  makefile_key_off.each do |target, count|
    it "passes the gates config on every rigor command of `make #{target}`" do
      commands = rigor_commands(makefile_recipe(target))
      expect(commands.size).to eq(count)
      expect(commands).to all(match(gates_flag)),
                          "`make #{target}` lost `--config .rigor.gates.yml`: #{commands.join(' | ')}"
    end
  end

  makefile_key_on.each do |target|
    it "leaves `make #{target}` on .rigor.dist.yml, where the key is on" do
      commands = rigor_commands(makefile_recipe(target))
      expect(commands).not_to be_empty
      expect(commands.grep(/--config/)).to be_empty, "`make #{target}` passes --config: #{commands.join(' | ')}"
    end
  end

  ci_steps.each do |name, side|
    it "keeps CI's #{name.inspect} step on its side of the split" do
      step = acceptance_steps.find { |s| s["name"] == name }
      expect(step).not_to be_nil, "ci.yml's acceptance-gates job has no step named #{name.inspect}"

      if side.is_a?(String)
        expect(step["run"].strip).to eq(side), "ci.yml step #{name.inspect} no longer runs only `#{side}`"
      else
        commands = rigor_commands(step["run"])
        expect(commands.size).to eq(side.last)
        expect(commands).to all(match(gates_flag)),
                            "ci.yml step #{name.inspect} lost `--config .rigor.gates.yml`: #{commands.join(' | ')}"
      end
    end
  end

  it "lists every acceptance-gates step that runs rigor" do
    unlisted = acceptance_steps.select { |step| runs_rigor?(step["run"]) }.map { |step| step["name"] } -
               self.class.ci_steps.keys
    expect(unlisted).to be_empty,
                        "ci.yml's acceptance-gates job runs rigor in #{unlisted.inspect}, which " \
                        "spec/rigor/self_check_gates_config_spec.rb does not list: add each to `ci_steps` on the " \
                        "side it belongs on (key off through `--config .rigor.gates.yml`, or a key-on Makefile target)"
  end
end
