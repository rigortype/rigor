# frozen_string_literal: true

# Suite-performance instrumentation (test-prof), loaded only when asked for.
#
# binpacker's timing file already answers "which files are slow". What it cannot
# answer is where an example's time goes once it starts: 98 % of the suite's
# measured example time sits in the ~2 100 examples that take 0.1 s or more, and
# each of those drives a real analysis behind some amount of `let` / `before`
# setup. Splitting the two is what says whether a file is slow because the work
# is genuinely expensive or because the setup is being redone per example.
#
# Every profiler is opt-in through test-prof's own env vars, so the default
# `make test` path does not even require the gem:
#
#   RD_PROF=1                — per-file split of `before`-hook vs `let` time
#   EVENT_PROF=rigor.analyze — attribute suite time to the engine entry points
#   TAG_PROF=type            — group time by example metadata
module SpecProfiling
  # test-prof's own set of `TestProf.activate` keys. A var outside it would
  # silently profile nothing, so the list is enumerated rather than prefixed.
  ENV_VARS = %w[
    EVENT_PROF FDOC FPROF LOG RD_PROF RSTAMP TAG_PROF TAG_PROF_EVENT
    TEST_MEM_PROF TEST_RUBY_PROF TEST_STACK_PROF TEST_VERNIER TPS_PROF
  ].freeze

  # Engine entry points worth attributing suite time to.
  #
  # `rigor.analyze` is one logical `rigor check`. `rigor.rbs_env` is the RBS
  # environment build underneath it — the cost `RunnerHelpers`' shared cache
  # store exists to amortise, so it doubles as the check on whether that sharing
  # still works: a run where the two totals are close is a suite paying for
  # environment builds rather than for analysis.
  #
  # Registered as blocks because `EventProf` patches only the events named in
  # `EVENT_PROF`, and requiring these eagerly would defeat the boot-slim that
  # `require "rigor"` performs.
  def self.register_events
    TestProf::EventProf::CustomEvents.register("rigor.analyze") do
      require "rigor/analysis/runner"
      TestProf::EventProf.monitor(Rigor::Analysis::Runner, "rigor.analyze", :run)
    end

    TestProf::EventProf::CustomEvents.register("rigor.rbs_env") do
      require "rigor/environment/rbs_loader"
      TestProf::EventProf.monitor(
        Rigor::Environment::RbsLoader.singleton_class, "rigor.rbs_env", :build_env_for
      )
    end
  end

  # `require "test-prof"` activates the events named in `EVENT_PROF` as it
  # loads, which is before anything here could have registered them. Activating
  # again afterwards is what makes the registrations above reachable;
  # `try_activate` consumes each registration, so the repeat is idempotent and
  # an already-activated or unknown name is a no-op.
  def self.activate_registered_events
    %w[EVENT_PROF TAG_PROF_EVENT].each do |var|
      events = ENV.fetch(var, nil)
      TestProf::EventProf::CustomEvents.activate_all(events) if events
    end
  end
end

if SpecProfiling::ENV_VARS.any? { |var| ENV[var] }
  require "test-prof"

  SpecProfiling.register_events
  SpecProfiling.activate_registered_events
end
