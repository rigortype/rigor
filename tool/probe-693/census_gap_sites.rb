# frozen_string_literal: true

# Movable-site probe for https://github.com/rigortype/rigor/issues/693.
#
# Prism only -- Rigor is deliberately not in the loop, so the counts are
# independent of the analyzer whose behaviour is being sized. What each column
# means, and what it is a floor or a ceiling for, is in tool/probe-693/README.md.

require "prism"
require "json"
require "set"

module Probe693
  CVAR_WRITES = [
    Prism::ClassVariableWriteNode, Prism::ClassVariableOrWriteNode,
    Prism::ClassVariableAndWriteNode, Prism::ClassVariableOperatorWriteNode
  ].freeze

  IVAR_WRITES = [
    Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode,
    Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableOperatorWriteNode
  ].freeze

  # An rvalue whose type the census could actually recover. Anything outside this
  # set records `Dynamic` even after the walk is fixed, so a site holding one
  # cannot move however the gap is closed.
  module Rvalue
    LITERALS = [
      Prism::StringNode, Prism::SymbolNode, Prism::IntegerNode, Prism::FloatNode,
      Prism::ArrayNode, Prism::HashNode, Prism::TrueNode, Prism::FalseNode,
      Prism::RegularExpressionNode, Prism::RationalNode, Prism::ImaginaryNode,
      Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode, Prism::LambdaNode
    ].freeze

    RECOVERABLE = %i[constant instantiation literal].freeze

    module_function

    # => :constant | :instantiation | :literal | :nil | :opaque
    def classify(node)
      case node
      when nil then :opaque
      when Prism::NilNode then :nil
      when Prism::ConstantReadNode, Prism::ConstantPathNode then :constant
      when Prism::CallNode then classify_call(node)
      when Prism::OrNode then merge(classify(node.left), classify(node.right))
      when Prism::AndNode then classify(node.right)
      else LITERALS.any? { |k| node.is_a?(k) } ? :literal : :opaque
      end
    end

    def classify_call(node)
      return :instantiation if node.name == :new && constant?(node.receiver)
      return classify(node.receiver) if %i[freeze dup -@].include?(node.name) && !constant?(node.receiver)

      :opaque
    end

    def constant?(node)
      node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
    end

    def merge(left, right)
      return left if left == right
      return right if left == :nil
      return left if right == :nil
      return :literal if RECOVERABLE.include?(left) && RECOVERABLE.include?(right)

      :opaque
    end

    def recoverable?(kind) = RECOVERABLE.include?(kind)
  end

  # Reads of a variable, split by whether a recovered type would reach a dispatch
  # decision. A read that is the RECEIVER of a call is where precision buys
  # something (`call.undefined-method`, a fold, a narrowing); a read that is
  # discarded or handed to an untyped sink moves nothing.
  class Reads
    def initialize
      @any = Hash.new(0)
      @consuming = Hash.new(0)
      # name => Set of method keys holding a CONSUMING read. A read in the same method
      # body as the write is already typed by flow, so only a foreign method key means
      # the census seed would buy something.
      @consuming_methods = Hash.new { |h, k| h[k] = Set.new }
    end

    attr_reader :any, :consuming, :consuming_methods

    def absorb(other)
      other.any.each { |n, c| @any[n] += c }
      other.consuming.each { |n, c| @consuming[n] += c }
      other.consuming_methods.each { |n, m| @consuming_methods[n].merge(m) }
      self
    end

    def record_tree(node, method_key = nil)
      return unless node.is_a?(Prism::Node)

      key = node.is_a?(Prism::DefNode) ? "#{node.name}@#{node.location.start_line}" : method_key
      case node
      when Prism::ClassVariableReadNode, Prism::InstanceVariableReadNode
        @any[node.name] += 1
      when Prism::CallNode
        r = node.receiver
        if r.is_a?(Prism::ClassVariableReadNode) || r.is_a?(Prism::InstanceVariableReadNode)
          @consuming[r.name] += 1
          @consuming_methods[r.name] << key
        end
      end
      node.compact_child_nodes.each { |c| record_tree(c, key) }
    end
  end

  Site = Struct.new(:shape, :file, :line, :owner, :name, :rvalue, :enclosing, :spelling, :method_key,
                    keyword_init: true)

  module Path
    module_function

    def flatten(node)
      case node
      when Prism::ConstantReadNode then [node.name.to_s]
      when Prism::ConstantPathNode
        return [node.name.to_s] if node.parent.nil?

        parent = flatten(node.parent)
        parent && (parent + [node.name.to_s])
      end
    end

    def child_prefix(current, constant_path)
      case constant_path
      when Prism::ConstantReadNode then current + [constant_path.name.to_s]
      when Prism::ConstantPathNode
        parts = flatten(constant_path)
        parts && (constant_path.parent.nil? ? parts : current + parts)
      end
    end
  end

  # One file. Mirrors ScopeIndexer#walk_class_cvars / #walk_class_ivars: a
  # declaration opens a new prefix, a plain `def` is where today's census
  # actually happens, and everything else is descended generically.
  class Walker
    def initialize(file)
      @file = file
      @sites = []
      @cvar_reads = Hash.new { |h, k| h[k] = Reads.new }   # class name  => Reads
      @singleton_reads = Hash.new { |h, k| h[k] = Reads.new } # class name  => Reads
      @block_reads = Hash.new { |h, k| h[k] = Reads.new }  # file:line   => Reads
      # Ivar names an ORDINARY `def` of each class writes. A gap-shape write of the
      # same name lands in the same census slot, which is where the contamination is.
      @instance_writes = Hash.new { |h, k| h[k] = Set.new }
    end

    attr_reader :sites, :cvar_reads, :singleton_reads, :block_reads, :instance_writes

    def run(root)
      walk(root, [])
      self
    end

    private

    def walk(node, prefix)
      return unless node.is_a?(Prism::Node)

      case node
      when Prism::ClassNode, Prism::ModuleNode
        child = Path.child_prefix(prefix, node.constant_path)
        if child
          if node.body
            # Cvar READS live in `def` bodies, which the site walk stops at, so the
            # whole declaration is indexed here in one sweep.
            @cvar_reads[child.join("::")].record_tree(node.body)
            walk(node.body, child)
          end
          return
        end
      when Prism::SingletonClassNode
        if node.expression.is_a?(Prism::SelfNode) && node.body && !prefix.empty?
          collect_singleton(node.body, prefix.join("::"))
        end
        return
      when Prism::DefNode
        if node.receiver.is_a?(Prism::SelfNode)
          collect_singleton(node, prefix.join("::")) unless prefix.empty?
        elsif !prefix.empty?
          # A plain `def` is censused today; its ivar names are what a gap-shape
          # write of the same name would collide with.
          each_node(node) do |n|
            @instance_writes[prefix.join("::")] << n.name if IVAR_WRITES.any? { |k| n.is_a?(k) }
          end
        end
        return
      when Prism::CallNode
        if anonymous_class_block?(node)
          collect_anonymous_class(node, prefix)
          return
        end
      end

      # Shape A: a cvar write reached WITHOUT passing through a `def`.
      if CVAR_WRITES.any? { |k| node.is_a?(k) } && !prefix.empty?
        @sites << Site.new(shape: :a_class_body_cvar, file: @file, line: node.location.start_line,
                           owner: prefix.join("::"), name: node.name, rvalue: Rvalue.classify(rvalue_of(node)))
      end

      node.compact_child_nodes.each { |c| walk(c, prefix) }
    end

    def rvalue_of(node) = node.respond_to?(:value) ? node.value : nil

    def anonymous_class_block?(node)
      node.name == :new && node.block.is_a?(Prism::BlockNode) &&
        node.receiver.is_a?(Prism::ConstantReadNode) &&
        %i[Class Module].include?(node.receiver.name)
    end

    # Shape B: `class << self` and `def self.x`. The class-ivar census table is
    # keyed per class with no facet split, and StatementEvaluator#seed_instance_ivars
    # returns early for a singleton body, so neither half of the pair is seeded.
    def collect_singleton(node, owner)
      @singleton_reads[owner].record_tree(node)
      # `class << self` carries no receiver on its defs, so collect_def_ivar_writes
      # types it as an INSTANCE ivar of the enclosing class; `def self.x` is at least
      # recognised as singleton by the write-mismatch collector.
      spelling = node.is_a?(Prism::DefNode) ? :self_def : :singleton_class
      record_ivar_writes(node, :b_singleton_ivar, owner, enclosing: owner, spelling: spelling)
    end

    # Shape C: `Klass = Class.new do … end`. At the top level the enclosing
    # prefix is empty, so collect_def_ivar_writes returns before recording.
    def collect_anonymous_class(call, prefix)
      owner = "#{@file}:#{call.location.start_line}"
      @block_reads[owner].record_tree(call.block)
      # An anonymous class nested inside a declaration is walked with the ENCLOSING
      # prefix, so its ivar writes are recorded against the enclosing class.
      record_ivar_writes(call.block, :c_anonymous_class_ivar, owner, enclosing: prefix.join("::"))
    end

    def record_ivar_writes(node, shape, owner, enclosing: nil, spelling: nil, method_key: nil)
      key = node.is_a?(Prism::DefNode) ? "#{node.name}@#{node.location.start_line}" : method_key
      each_node(node) do |n|
        if n.is_a?(Prism::DefNode) && !n.equal?(node)
          record_ivar_writes(n, shape, owner, enclosing: enclosing, spelling: spelling,
                                             method_key: "#{n.name}@#{n.location.start_line}")
          next :skip
        end
        next unless IVAR_WRITES.any? { |k| n.is_a?(k) }

        @sites << Site.new(shape: shape, file: @file, line: n.location.start_line,
                           owner: owner, name: n.name, rvalue: Rvalue.classify(rvalue_of(n)),
                           enclosing: enclosing, spelling: spelling, method_key: key)
      end
    end

    def each_node(node, &block)
      return unless node.is_a?(Prism::Node)

      return if block.call(node) == :skip

      node.compact_child_nodes.each { |c| each_node(c, &block) }
    end
  end
end

# ---------------------------------------------------------------------------

target = ARGV[0] or abort("usage: census_gap_sites.rb <root> [subdir ...]")
subdirs = ARGV[1..]
subdirs = [""] if subdirs.nil? || subdirs.empty?

files = subdirs.flat_map do |sub|
  Dir.glob(File.join(sub.empty? ? target : File.join(target, sub), "**", "*.rb"))
end.uniq.sort

sites = []
cvar_reads = Hash.new { |h, k| h[k] = Probe693::Reads.new }
singleton_reads = Hash.new { |h, k| h[k] = Probe693::Reads.new }
block_reads = Hash.new { |h, k| h[k] = Probe693::Reads.new }
instance_writes = Hash.new { |h, k| h[k] = Set.new }
parsed = 0

files.each do |path|
  begin
    src = File.read(path, encoding: "UTF-8")
    result = Prism.parse(src)
  rescue ArgumentError, Encoding::UndefinedConversionError, Errno::ENOENT
    next
  end
  next unless result.success?

  parsed += 1
  walker = Probe693::Walker.new(path.delete_prefix(target).delete_prefix("/")).run(result.value)
  sites.concat(walker.sites)
  walker.cvar_reads.each { |k, v| cvar_reads[k].absorb(v) }
  walker.singleton_reads.each { |k, v| singleton_reads[k].absorb(v) }
  walker.block_reads.each { |k, v| block_reads[k].absorb(v) }
  walker.instance_writes.each { |k, v| instance_writes[k].merge(v) }
end

reads_for = lambda do |site|
  case site.shape
  when :a_class_body_cvar then cvar_reads[site.owner]
  when :b_singleton_ivar then singleton_reads[site.owner]
  else block_reads[site.owner]
  end
end

rows = sites.map do |s|
  r = reads_for.call(s)
  recoverable = Probe693::Rvalue.recoverable?(s.rvalue)
  consuming = r.consuming[s.name]
  # A collision is where the gap stops being precision-only: the gap-shape write is
  # recorded in the SAME census slot as the enclosing class's own instance ivar of
  # that name, so the two types union and `def.ivar-write-mismatch` can fire on
  # correct Ruby. `def self.x` is exempt -- the write-mismatch collector already
  # recognises that spelling as singleton.
  collides = !s.enclosing.nil? && s.spelling != :self_def && instance_writes[s.enclosing].include?(s.name)
  foreign = (r.consuming_methods[s.name] - [s.method_key]).size
  { shape: s.shape, file: s.file, line: s.line, owner: s.owner, name: s.name, rvalue: s.rvalue,
    spelling: s.spelling, enclosing: s.enclosing,
    reads: r.any[s.name], consuming_reads: consuming, foreign_consuming_methods: foreign,
    recoverable: recoverable, movable: recoverable && foreign.positive?, collides: collides }
end

summary = Hash.new { |h, k| h[k] = Hash.new(0) }
rows.each do |row|
  s = summary[row[:shape]]
  s[:sites] += 1
  s[:recoverable] += 1 if row[:recoverable]
  s[:with_read] += 1 if row[:reads].positive?
  s[:with_consuming_read] += 1 if row[:consuming_reads].positive?
  s[:cross_method] += 1 if row[:foreign_consuming_methods].positive?
  s[:movable] += 1 if row[:movable]
  s[:collides] += 1 if row[:collides]
end

if ENV["PROBE693_FORMAT"] == "json"
  puts JSON.pretty_generate(target: target, subdirs: subdirs, files: parsed, summary: summary, rows: rows)
else
  puts "target: #{target} [#{subdirs.join(" ")}]  files parsed: #{parsed}"
  %i[a_class_body_cvar b_singleton_ivar c_anonymous_class_ivar].each do |shape|
    s = summary[shape]
    puts format("  %-24s sites=%-6d recoverable=%-6d with_read=%-6d consuming=%-6d cross_method=%-6d MOVABLE=%-5d COLLIDES=%d",
                shape, s[:sites], s[:recoverable], s[:with_read], s[:with_consuming_read],
                s[:cross_method], s[:movable], s[:collides])
  end
end
