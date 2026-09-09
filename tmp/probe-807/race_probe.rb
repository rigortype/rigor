# frozen_string_literal: true

# Probe: how reliably does the #807 marker race surface as an exception out of a
# concurrent fetch_or_compute? Two shapes are measured.

require "tmpdir"
require "fileutils"
require "rigor/cache/store"
require "rigor/cache/descriptor"

DESCRIPTOR = Rigor::Cache::Descriptor.new

def round(root, threads: 16, fetches: 1)
  errors = []
  mutex = Mutex.new
  Array.new(threads) do |i|
    Thread.new do
      store = Rigor::Cache::Store.new(root: root)
      fetches.times do |n|
        store.fetch_or_compute(
          producer_id: "p", generation_cap: :unbounded, params: { n: n }, descriptor: DESCRIPTOR
        ) { "value-#{i}-#{n}" }
      end
    rescue StandardError => e
      mutex.synchronize { errors << e }
    end
  end.each(&:join)
  errors
end

def shape_fresh(dir, i)
  root = File.join(dir, "fresh-#{i}")
  round(root, threads: 16, fetches: 3)
end

def shape_stale(dir, i)
  root = File.join(dir, "stale-#{i}")
  FileUtils.mkdir_p(root)
  # A root left by a previous Rigor version: every constructor takes the clear path.
  seed = Rigor::Cache::Store.new(root: root)
  3.times do |n|
    seed.fetch_or_compute(
      producer_id: "p", generation_cap: :unbounded, params: { n: n }, descriptor: DESCRIPTOR
    ) { "seed-#{n}" }
  end
  File.write(File.join(root, "schema_version.txt"), "0.0.0.0.0\n")
  round(root, threads: 16, fetches: 3)
end

ROUNDS = Integer(ENV.fetch("ROUNDS", "20"))

Dir.mktmpdir("race-probe-") do |dir|
  %i[shape_fresh shape_stale].each do |shape|
    failed = 0
    samples = []
    ROUNDS.times do |i|
      errors = send(shape, dir, i)
      unless errors.empty?
        failed += 1
        samples << errors.first
      end
    end
    puts "#{shape}: #{failed}/#{ROUNDS} rounds raised"
    samples.first(3).each { |e| puts "    #{e.class}: #{e.message}" }
  end
end
