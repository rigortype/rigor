# frozen_string_literal: true

require "rigor"
require "yaml"

# #3324 (variant B on #3353): the self-check proper reads `.rigor.dist.yml` with `parameter_inference: true`, and the
# consistency and precision gates read `.rigor.gates.yml`, which is the same configuration with the key off. This
# spec keeps the split from drifting: the gates file differs from the dist file in that one key alone, every gate
# listed below passes it with `--config`, and the self-check targets do not.
RSpec.describe "The self-check's gates configuration" do
  def repo_root
    File.expand_path("../..", __dir__)
  end

  def gates_flag = "--config .rigor.gates.yml"

  def makefile_recipe(target)
    lines = File.readlines(File.join(repo_root, "Makefile"))
    start = lines.index { |line| line.start_with?("#{target}:") }
    raise "Makefile has no `#{target}:` target" if start.nil?

    lines[(start + 1)..].take_while { |line| line.start_with?("\t") }.map(&:strip)
  end

  def acceptance_step(name)
    ci = YAML.safe_load_file(File.join(repo_root, ".github/workflows/ci.yml"))
    step = ci.dig("jobs", "acceptance-gates", "steps").find { |s| s["name"] == name }
    raise "ci.yml's acceptance-gates job has no step named #{name.inspect}" if step.nil?

    step.fetch("run")
  end

  def rigor_commands(text)
    text.lines.map(&:strip).grep(%r{exe/rigor (check|coverage)})
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

  {
    "coverage" => 1,
    "check-incremental" => 2
  }.each do |target, count|
    it "passes the gates config on every rigor command of `make #{target}`" do
      commands = rigor_commands(makefile_recipe(target).join("\n"))
      expect(commands.size).to eq(count)
      expect(commands).to all(include(gates_flag)), "`make #{target}` lost `#{gates_flag}`: #{commands.join(' | ')}"
    end
  end

  { "Run the callee-floor memo audit" => 1, "Run the type_of shadow (advisory)" => 2 }.each do |name, count|
    it "passes the gates config on every rigor command of CI's #{name.inspect} step" do
      commands = rigor_commands(acceptance_step(name))
      expect(commands.size).to eq(count)
      expect(commands).to all(include(gates_flag)),
                          "ci.yml step #{name.inspect} lost `#{gates_flag}`: #{commands.join(' | ')}"
    end
  end

  %w[check check-json check-plugins].each do |target|
    it "leaves `make #{target}` on .rigor.dist.yml, where the key is on" do
      commands = rigor_commands(makefile_recipe(target).join("\n"))
      expect(commands).not_to be_empty
      expect(commands.grep(/--config/)).to be_empty, "`make #{target}` passes --config: #{commands.join(' | ')}"
    end
  end
end
