#!/usr/bin/env ruby
# frozen_string_literal: true

# Measures what each spec file under a mirror directory costs, for the time budget
# `bin/verify-changed` puts on a mirror directory (#3289), and rewrites tool/spec_costs.tsv.
#
# A mirror directory is a spec directory a changed lib/ or tool/ file selects from:
# `spec/<x>/` beside `lib/<x>.rb`, or `spec/tool/<x>/` beside `tool/<x>.rb`, never the
# unit-spec root `spec/rigor/`. The same-named `spec/<x>_spec.rb` is measured too, since the
# budget charges it first. A file's cost is the seconds it adds to one rspec process:
# loading it, plus its top-level groups (hooks and examples). The process's own boot is
# not in it; a run pays that once whatever it selects.
#
# The table is the input `bin/verify-changed` reads, so a fresh clone needs no prior run and
# every machine selects the same specs. To keep it from churning between parallel branches,
# a refresh keeps a row whose old value is within a factor of two of the new one; only a
# file that got much slower or faster, a new file, or a deleted one moves a line. Run it on
# an idle host, one directory at a time if you like:
#
#   bundle exec ruby tool/spec_costs.rb                 # every mirror directory
#   bundle exec ruby tool/spec_costs.rb spec/rigor/cli spec/rigor/cli_spec.rb  # just these
#
# `bundle exec rspec -r ./tool/spec_costs.rb …` with SPEC_COSTS_OUT set is the probe the
# refresh runs in each child process.
require "fileutils"
require "json"
require "open3"

module SpecCosts
  TABLE = "tool/spec_costs.tsv"
  KEEP_WITHIN = 2.0

  module_function

  # Every mirror directory under `root`, sorted.
  def mirror_dirs(root = Dir.pwd)
    sources = Dir.glob("lib/**/*.rb", base: root).map do |path|
      "spec/#{path.delete_prefix('lib/').delete_suffix('.rb')}"
    end +
              Dir.glob("tool/**/*.rb", base: root).map { |path| "spec/#{path.delete_suffix('.rb')}" }
    sources.uniq.reject { |dir| dir == "spec/rigor" }.select { |dir| File.directory?(File.join(root, dir)) }.sort
  end

  # Every spec file under a mirror directory, and the same-named spec beside one, sorted.
  def mirrored_specs(root = Dir.pwd)
    mirror_dirs(root).flat_map do |dir|
      [*Dir.glob("#{dir}/**/*_spec.rb", base: root), *same_named_spec(dir, root)]
    end.uniq.sort
  end

  # The same-named spec beside a mirror directory, when there is one.
  def same_named_spec(dir, root = Dir.pwd) = ["#{dir}_spec.rb"].select { |path| File.file?(File.join(root, path)) }

  # What a full refresh measures: every mirror directory and every same-named spec.
  def targets(root = Dir.pwd) = mirror_dirs(root).flat_map { |dir| [dir, *same_named_spec(dir, root)] }

  # { path => seconds } from the table's text; `#` lines are comments.
  def parse(text)
    text.each_line.reject { |line| line.start_with?("#") || line.strip.empty? }.to_h do |line|
      cost, path = line.chomp.split("\t", 2)
      [path, Float(cost)]
    end
  end

  # The header comment lines of the table's text.
  def header(text) = text.each_line.take_while { |line| line.start_with?("#") }.join

  # The new rows: measured files take their new value unless the old one is within
  # KEEP_WITHIN of it; rows for files that no longer exist are dropped.
  def merge(old, measured, existing)
    rows = old.slice(*existing)
    measured.each do |path, seconds|
      seconds = [seconds.round(2), 0.01].max
      previous = rows[path]
      next if previous && seconds <= previous * KEEP_WITHIN && seconds >= previous / KEEP_WITHIN

      rows[path] = seconds
    end
    rows.sort.to_h
  end

  def format(header, rows) = header + rows.map { |path, seconds| "#{format_seconds(seconds)}\t#{path}\n" }.join

  def format_seconds(seconds) = Kernel.format("%.2f", seconds)

  # { path => seconds } over `targets` (spec directories or files), one rspec process each. The
  # probe's output file is deleted before each run, so a child that dies before writing one
  # records nothing rather than handing back an earlier run's numbers.
  def measure(targets)
    FileUtils.mkdir_p("tmp")
    targets.each_with_object({}) do |target, measured|
      out = File.join("tmp", "spec_costs_#{target.tr('/', '_')}.json")
      FileUtils.rm_f(out)
      command = ["bundle", "exec", "rspec", "-r", "./tool/spec_costs.rb", target]
      _, err, status = Open3.capture3({ "SPEC_COSTS_OUT" => out }, *command, stdin_data: "")
      warn "#{target}: rspec exited #{status.exitstatus}; what it recorded is kept\n#{err}" unless status.success?
      measured.merge!(JSON.parse(File.read(out))) if File.exist?(out)
    end
  end

  def refresh(targets)
    measured = measure(targets)
    text = File.exist?(TABLE) ? File.read(TABLE) : ""
    rows = merge(parse(text), measured, mirrored_specs)
    File.write(TABLE, format(header(text), rows))
  end

  # The in-process probe, installed when rspec requires this file.
  module Probe
    TIMES = Hash.new(0.0)

    def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def self.relative(path) = path.delete_prefix("./")

    module Load
      def load_file_handling_errors(method, file)
        start = Probe.now
        super
      ensure
        Probe::TIMES[Probe.relative(RSpec::Core::Metadata.relative_path(file))] += Probe.now - start
      end
    end

    class Listener
      def initialize = @started = {}

      def example_group_started(notification)
        @started[notification.group] = Probe.now if notification.group.top_level?
      end

      def example_group_finished(notification)
        group = notification.group
        return unless group.top_level?

        Probe::TIMES[Probe.relative(group.metadata[:file_path])] += Probe.now - @started.delete(group)
      end
    end

    def self.install(out)
      RSpec::Core::Configuration.prepend(Load)
      RSpec.configure do |config|
        config.reporter.register_listener(Listener.new, :example_group_started, :example_group_finished)
        config.after(:suite) { File.write(out, JSON.generate(TIMES)) }
      end
    end
  end
end

if defined?(RSpec::Core) && ENV["SPEC_COSTS_OUT"]
  SpecCosts::Probe.install(ENV.fetch("SPEC_COSTS_OUT"))
elsif $PROGRAM_NAME == __FILE__
  SpecCosts.refresh(ARGV.empty? ? SpecCosts.targets : ARGV)
end
