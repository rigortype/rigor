# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "rigor/cache/store"
require "rigor/cache/descriptor"

DESCRIPTOR = Rigor::Cache::Descriptor.new
ENTRIES = Integer(ENV.fetch("ENTRIES", "300"))
THREADS = Integer(ENV.fetch("THREADS", "16"))
ROUNDS = Integer(ENV.fetch("ROUNDS", "10"))

def seed(root)
  store = Rigor::Cache::Store.new(root: root)
  ENTRIES.times do |n|
    store.fetch_or_compute(
      producer_id: "p", generation_cap: :unbounded, params: { n: n }, descriptor: DESCRIPTOR
    ) { "seed-#{n}" }
  end
end

def race(root)
  errors = []
  mutex = Mutex.new
  Array.new(THREADS) do
    Thread.new do
      store = Rigor::Cache::Store.new(root: root)
      ENTRIES.times do |n|
        store.fetch_or_compute(
          producer_id: "p", generation_cap: :unbounded, params: { n: n }, descriptor: DESCRIPTOR
        ) { "recomputed-#{n}" }
      end
    rescue StandardError => e
      mutex.synchronize { errors << e }
    end
  end.each(&:join)
  errors
end

failed = 0
samples = []
Dir.mktmpdir("race-probe2-") do |dir|
  ROUNDS.times do |i|
    root = File.join(dir, "r-#{i}")
    seed(root)
    # A root left behind by a previous Rigor release: every process that starts now takes the
    # clear-the-root path in its constructor.
    File.write(File.join(root, "schema_version.txt"), "0.0.0.0.0\n")
    errors = race(root)
    unless errors.empty?
      failed += 1
      samples.concat(errors.first(2))
    end
  end
end
puts "#{failed}/#{ROUNDS} rounds raised"
samples.first(5).each { |e| puts "  #{e.class}: #{e.message}\n    #{e.backtrace.find { |l| l.include?('store.rb') }}" }
