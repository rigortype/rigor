# frozen_string_literal: true
# Cross-PROCESS shape: N processes construct a Store on one fresh root at the same instant.
# Does any of them observe a torn/empty marker and clear the root?
require "tmpdir"
require "fileutils"
require "rigor/cache/store"
require "rigor/cache/descriptor"

DESCRIPTOR = Rigor::Cache::Descriptor.new
PROCS = Integer(ENV.fetch("PROCS", "12"))
ROUNDS = Integer(ENV.fetch("ROUNDS", "40"))

rounds_with_clear = 0
total_clears = 0
Dir.mktmpdir("race-probe5-") do |dir|
  ROUNDS.times do |r|
    root = File.join(dir, "r-#{r}")
    FileUtils.mkdir_p(root)
    flag = File.join(dir, "cleared-#{r}")
    start = Time.now + 0.15
    pids = Array.new(PROCS) do |i|
      fork do
        spy = Class.new(Rigor::Cache::Store) do
          define_method(:clear_cache_root!) do
            File.open(flag, "a") { |f| f.puts Process.pid }
            super()
          end
        end
        sleep([start - Time.now, 0].max)
        spy.new(root: root).fetch_or_compute(
          producer_id: "p", generation_cap: :unbounded, params: { i: i }, descriptor: DESCRIPTOR
        ) { "v-#{i}" }
        exit!(0)
      end
    end
    pids.each { |pid| Process.wait(pid) }
    next unless File.exist?(flag)

    rounds_with_clear += 1
    total_clears += File.readlines(flag).size
  end
end
puts "clears on a FRESH root: #{total_clears} total, in #{rounds_with_clear}/#{ROUNDS} rounds (#{PROCS} procs each)"
