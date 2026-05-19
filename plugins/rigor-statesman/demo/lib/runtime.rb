# frozen_string_literal: true

# Tiny state-machine runtime. Just enough to make demo.rb
# runnable; the plugin's value is in the lint-time check
# of the `transition_to(:state)` calls below.

class Class
  def state_machine(&)
    machine = StateMachine.new
    machine.instance_exec(&)
    instance_variable_set(:@state_machine, machine)

    define_method(:transition_to) do |target|
      machine = self.class.instance_variable_get(:@state_machine)
      raise ArgumentError, "unknown state :#{target}" unless machine.states.include?(target)

      @state = target
    end

    define_method(:state) do
      @state ||= self.class.instance_variable_get(:@state_machine).initial_state
    end
  end
end

class StateMachine
  attr_reader :states, :initial_state

  def initialize
    @states = []
  end

  def state(name, initial: false)
    @states << name
    @initial_state = name if initial
  end

  # Runtime stub for `event :name do ... end`. The plugin does
  # NOT yet introspect events; real DSL plugins would extend
  # the collector to track per-event from/to declarations.
  def event(_name, &)
    nil
  end
end
