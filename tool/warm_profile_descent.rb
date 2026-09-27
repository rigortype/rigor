# frozen_string_literal: true

# The breakdown `tool/engine_warm_ab.rb`'s profiler preload writes (#1507), kept here so the spec can drive it: the
# preload `require`s this file by absolute path inside the profiled `rigor check` process.
#
# `stacks` maps a root-first array of frame labels to its sample weight. The chain follows the frame that nearly
# every sample shares, descending while one child holds at least `share` of ALL samples, so a dominant phase is
# opened rather than hidden and at most `1 - share` of the samples is off the chain. `phases` is where the samples
# fan out below it, and `inner` opens the heaviest phase one level more, which is what a short run whose chain
# stops at `<main>` needs.
module WarmProfileDescent
  module_function

  def call(stacks, share: 0.9, limit: 15)
    total = stacks.values.sum
    level = 0
    current = stacks
    chain = []
    loop do
      label, weight = children(current, level).max_by { |_, w| w }
      break if label.nil? || weight < share * total

      chain << [label, weight]
      current = current.select { |stack, _| stack[level] == label }
      level += 1
    end
    phases = children(current, level, self_label: "(self)")
    heaviest = phases.max_by { |_, w| w }&.first
    inner = heaviest && heaviest != "(self)" ? children(current.select { |stack, _| stack[level] == heaviest }, level + 1) : {}
    { "chain" => chain, "phases" => top(phases, limit), "inner" => [heaviest, top(inner, limit)] }
  end

  def children(stacks, level, self_label: nil)
    counts = Hash.new(0)
    stacks.each do |stack, weight|
      label = stack[level] || self_label
      counts[label] += weight if label
    end
    counts
  end

  def top(counts, limit) = counts.sort_by { |label, weight| [-weight, label] }.first(limit)
end
