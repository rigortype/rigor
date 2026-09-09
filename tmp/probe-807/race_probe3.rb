# frozen_string_literal: true

# Fresh-root shape: concurrent constructors race the FIRST `schema_version.txt` write. A torn/empty
# read makes a constructor clear the root, destroying entries a sibling already wrote.

require "tmpdir"
require "fileutils"
require "rigor/cache/store"
require "rigor/cache/descriptor"

DESCRIPTOR = Rigor::Cache::Descriptor.new
THREADS = Integer(ENV.fetch("THREADS", "16"))
PER_THREAD = Integer(ENV.fetch("PER_THREAD", "20"))
ROUNDS = Integer(ENV.fetch("ROUNDS", "20"))

def race(root)
  errors = []
  mutex = Mutex.new
  Array.new(THREADS) do |i|
    Thread.new do
      store = Rigor::Cache::Store.new(root: root)
      PER_THREAD.times do |n|
        store.fetch_or_compute(
          producer_id: "p", generation_cap: :unbounded, params: { i: i, n: n }, descriptor: DESCRIPTOR
        ) { "value-#{i}-#{n}" }
      end
    rescue StandardError => e
      mutex.synchronize { errors << e }
    end
  end.each(&:join)
  errors
end

lost = 0
raised = 0
Dir.mktmpdir("race-probe3-") do |dir|
  ROUNDS.times do |i|
    root = File.join(dir, "r-#{i}")
    errors = race(root)
    raised += 1 unless errors.empty?
    on_disk = Dir.glob(File.join(root, "**", "*.entry")).size
    lost += 1 if on_disk < THREADS * PER_THREAD
    puts "  round #{i}: entries=#{on_disk}/#{THREADS * PER_THREAD} errors=#{errors.size}" if on_disk < THREADS * PER_THREAD || !errors.empty?
  end
end
puts "#{lost}/#{ROUNDS} rounds lost entries; #{raised}/#{ROUNDS} rounds raised"
