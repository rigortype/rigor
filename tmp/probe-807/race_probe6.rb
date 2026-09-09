# frozen_string_literal: true
require "tmpdir"
require "fileutils"
require "rigor/cache/store"
require "rigor/cache/descriptor"

DESCRIPTOR = Rigor::Cache::Descriptor.new
ENTRIES = Integer(ENV.fetch("ENTRIES", "200"))
THREADS = Integer(ENV.fetch("THREADS", "16"))
ROUNDS = Integer(ENV.fetch("ROUNDS", "10"))

def seed(root)
  store = Rigor::Cache::Store.new(root: root)
  ENTRIES.times do |n|
    store.fetch_or_compute(producer_id: "p", generation_cap: :unbounded, params: { n: n }, descriptor: DESCRIPTOR) { "s-#{n}" }
  end
end

def race(root)
  errors = []
  mutex = Mutex.new
  gate = Queue.new
  threads = Array.new(THREADS) do
    Thread.new do
      gate.pop
      store = Rigor::Cache::Store.new(root: root)
      ENTRIES.times do |n|
        store.fetch_or_compute(producer_id: "p", generation_cap: :unbounded, params: { n: n }, descriptor: DESCRIPTOR) { "r-#{n}" }
      end
    rescue StandardError => e
      mutex.synchronize { errors << e }
    end
  end
  sleep 0.05
  THREADS.times { gate << :go }
  threads.each(&:join)
  errors
end

failed = 0
sample = nil
Dir.mktmpdir("race-probe6-") do |dir|
  ROUNDS.times do |i|
    root = File.join(dir, "r-#{i}")
    seed(root)
    File.write(File.join(root, "schema_version.txt"), "0.0.0.0.0\n")
    errors = race(root)
    unless errors.empty?
      failed += 1
      sample ||= errors.first
    end
  end
end
puts "#{failed}/#{ROUNDS} rounds raised"
puts "  #{sample.class}: #{sample.backtrace.find { |l| l.include?('store.rb') }}" if sample
