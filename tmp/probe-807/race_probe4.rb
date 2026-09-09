# frozen_string_literal: true
# Does a concurrent constructor ever OBSERVE a torn/empty marker on a fresh root?
require "tmpdir"
require "fileutils"
require "rigor/cache/store"
require "rigor/cache/descriptor"

DESCRIPTOR = Rigor::Cache::Descriptor.new
THREADS = Integer(ENV.fetch("THREADS", "24"))
ROUNDS = Integer(ENV.fetch("ROUNDS", "200"))

clears = 0
mutex = Mutex.new
spy = Class.new(Rigor::Cache::Store) do
  define_method(:clear_cache_root!) do
    mutex.synchronize { clears += 1 }
    super()
  end
end

rounds_with_clear = 0
Dir.mktmpdir("race-probe4-") do |dir|
  ROUNDS.times do |r|
    root = File.join(dir, "r-#{r}")
    FileUtils.mkdir_p(root)
    before = clears
    barrier = Queue.new
    threads = Array.new(THREADS) do |i|
      Thread.new do
        barrier.pop
        spy.new(root: root).fetch_or_compute(
          producer_id: "p", generation_cap: :unbounded, params: { i: i }, descriptor: DESCRIPTOR
        ) { "v-#{i}" }
      rescue StandardError
        nil
      end
    end
    sleep 0.01
    THREADS.times { barrier << :go }
    threads.each(&:join)
    rounds_with_clear += 1 if clears > before
  end
end
puts "clears on a FRESH root: #{clears} total, in #{rounds_with_clear}/#{ROUNDS} rounds"
