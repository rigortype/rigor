# frozen_string_literal: true

# THROWAWAY — issue #345 spike. Applies the decay stages 3 and 4 to a probe dump's class/module
# candidate tier, and prints the surviving set.
#
#   ruby tool/unused_probe/stages.rb PROBE.json --project DIR [--json]
#
# Stage 3 (ROUTE ROOTS) subtracts controllers reachable from `config/routes.rb`. The extractor here
# is DELIBERATELY ROUGH — a line-oriented regex scan, not a Rails router. It is sized to answer
# "how big is the drop", not to be the #349 implementation. Known roughness, all deliberate:
#   * block nesting is tracked by counting `do` / `end`, so a one-line `do … end` miscounts;
#   * `resource :x` (singular) contributes BOTH `XController` and `XsController` because there is
#     no inflector here;
#   * a `'a/b#c'` string contributes both the namespaced and the bare form;
#   * matching is on the full constant name OR its demodulized tail, so `Api::V1::FooController`
#     is subtracted by a bare `FooController` root. This over-subtracts, which is the safe
#     direction for an FP-baseline measurement.
#
# Stage 4 (DYNAMIC-RESOLUTION DEMOTION) moves to a "cannot decide" bucket every candidate whose
# name could plausibly be produced or named outside Ruby constant syntax:
#   d1  its enclosing namespace is a literal prefix of a `constantize` / `safe_constantize` /
#       `const_get` / string-interpolation constant construction;
#   d2  its fully-qualified name appears inside a Ruby string or symbol literal;
#   d3  its name (FQN, autoload path form, or underscored tail) appears in an ERB / HAML / SLIM /
#       YAML / locale / JSON file under the project.

require "json"
require "optparse"

options = { project: nil, json: false, list: false }
parser = OptionParser.new do |opts|
  opts.banner = "usage: ruby tool/unused_probe/stages.rb PROBE.json --project DIR [--json] [--list]"
  opts.on("--project DIR", "the analyzed project root (for routes + dynamic scan)") { |v| options[:project] = v }
  opts.on("--json", "machine-readable output") { options[:json] = true }
  opts.on("--list", "print every surviving candidate") { options[:list] = true }
end
parser.parse!
probe = ARGV.shift or abort(parser.banner)
project = options[:project] or abort(parser.banner)
project = File.expand_path(project)

here = File.expand_path(__dir__)
report = JSON.parse(`ruby #{here}/report.rb #{probe} --json`)
abort("report.rb refused to report") unless $CHILD_STATUS.nil? || $?.success?

class_candidates = report["candidates_list"].select { |c| c["bucket"] == "class" }

# ---------------------------------------------------------------------------------------------
# Stage 3 — rough route-root extraction.
# ---------------------------------------------------------------------------------------------
def camelize(token)
  token.to_s.split("/").map { |seg| seg.split("_").map(&:capitalize).join }.join("::")
end

def route_files(project)
  files = []
  files << File.join(project, "config/routes.rb")
  files.concat(Dir[File.join(project, "config/routes/**/*.rb")])
  files.select { |f| File.file?(f) }
end

def extract_route_roots(project)
  roots = Set.new
  route_files(project).each do |file|
    depth = 0
    mods = [] # [depth_at_open, segment]
    File.read(file, encoding: "UTF-8").scrub.each_line do |raw|
      # Strip a trailing comment only when the `#` starts a token: a route's `"controller#action"`
      # string has no space before its `#`, and `#{}` interpolation is kept.
      line = raw.sub(/(?:\A|\s)#(?!\{).*$/, "")
      opens = /\bdo\b\s*(\|[^|]*\|)?\s*$/.match?(line)

      segment = nil
      segment = camelize(Regexp.last_match(1)) if line =~ %r{^\s*namespace\s+[:'"]([\w/]+)}
      segment = camelize(Regexp.last_match(1)) if line =~ %r{(?::module\s*=>|\bmodule:)\s*['":]([\w/]+)}
      prefix = mods.map(&:last).join("::")
      scoped = ->(name) { prefix.empty? ? name : "#{prefix}::#{name}" }

      # resources :a, :b / resource :a
      if line =~ /^\s*(resources?)\s+(.+)$/
        kind = Regexp.last_match(1)
        Regexp.last_match(2).scan(/:([a-z_]\w*)/) do |(tok)|
          base = camelize(tok)
          roots << scoped.call("#{base}Controller")
          roots << scoped.call("#{base}sController") if kind == "resource"
        end
      end
      # explicit `controller:` / `:controller =>` / `controllers foo: 'bar'`
      line.scan(%r{(?::controller\s*=>|\bcontrollers?\b[^#]*?[:=>]{1,2})\s*['"]([\w/]+)['"]}) do |(tok)|
        roots << scoped.call("#{camelize(tok)}Controller")
        roots << "#{camelize(tok)}Controller"
      end
      # "controller#action" strings, in any position (to:, root, get 'x' => 'y#z', …)
      line.scan(%r{['"]([a-z_][\w/]*)#\w+['"]}) do |(tok)|
        roots << scoped.call("#{camelize(tok)}Controller")
        roots << "#{camelize(tok)}Controller"
      end

      mods << [depth, segment] if segment && opens
      depth += 1 if opens
      if /^\s*end\b/.match?(line)
        depth -= 1
        mods.pop while mods.any? && mods.last.first >= depth
      end
    end
  end
  roots
end

# ---------------------------------------------------------------------------------------------
# Stage 4 — dynamic-resolution scan.
# ---------------------------------------------------------------------------------------------
SCAN_DIRS = %w[app lib config db].freeze
NON_RUBY_EXT = %w[.erb .haml .slim .yml .yaml .json .rabl .jbuilder .builder].freeze

def scan_files(project)
  rb = []
  other = []
  SCAN_DIRS.each do |dir|
    root = File.join(project, dir)
    next unless File.directory?(root)

    Dir[File.join(root, "**", "*")].each do |path|
      next unless File.file?(path)

      ext = File.extname(path)
      if [".rb", ".rake"].include?(ext)
        rb << path
      elsif NON_RUBY_EXT.include?(ext)
        other << path
      end
    end
  end
  [rb, other]
end

def underscore(name)
  name.gsub("::", "/").gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
end

def dynamic_scan(project)
  rb, other = scan_files(project)
  namespaces = Set.new
  toplevel_dynamic = false
  literals = +""
  rb.each do |path|
    src = File.read(path, encoding: "UTF-8").scrub
    # d1: a literal constant prefix immediately before an interpolation or a dynamic join.
    src.scan(/["']((?:[A-Z]\w*::)+)(?:#\{|["']\s*[+.])/) { |(pre)| namespaces << pre.sub(/::\z/, "") }
    src.scan(/([A-Z][\w:]*)\.const_get/) { |(recv)| namespaces << recv }
    # a bare `"#{...}"` fed to constantize / const_get means ANY top-level name is reachable.
    toplevel_dynamic ||= /["']#\{[^}]*\}\w*["']\s*\.\s*(safe_)?constantize/.match?(src)
    toplevel_dynamic ||= /(safe_)?constantize/.match?(src) && /["']#\{/.match?(src)
    # d2: every string / symbol literal body.
    src.scan(/"([^"\\\n]{0,200})"|'([^'\\\n]{0,200})'|:"([^"\n]{0,200})"/) do |m|
      literals << (m.compact.first || "") << "\n"
    end
  end
  non_ruby = +""
  other.each { |path| non_ruby << File.read(path, encoding: "UTF-8").scrub << "\n" }
  { namespaces: namespaces, toplevel: toplevel_dynamic, literals: literals, non_ruby: non_ruby }
end

def dynamic_reason(name, scan)
  parent = name.include?("::") ? name.rpartition("::").first : ""
  return "d1-dynamic-namespace" if !parent.empty? && scan[:namespaces].include?(parent)
  return "d1-toplevel-dynamic" if parent.empty? && scan[:toplevel] && name.end_with?("Controller")
  return "d2-ruby-string-literal" if scan[:literals].include?(name)

  tail = name.split("::").last
  variants = [name, underscore(name), underscore(tail)]
  return "d3-non-ruby-file" if variants.any? { |v| scan[:non_ruby].include?(v) }

  nil
end

# ---------------------------------------------------------------------------------------------
roots = extract_route_roots(project)
root_tails = roots.map { |r| r.split("::").last }.to_set
scan = dynamic_scan(project)

stage3_removed = []
stage4_removed = []
survivors = []
class_candidates.each do |cand|
  name = cand["name"]
  if roots.include?(name) || root_tails.include?(name.split("::").last)
    stage3_removed << cand
    next
  end
  reason = dynamic_reason(name, scan)
  if reason
    stage4_removed << cand.merge("reason" => reason)
    next
  end
  survivors << cand
end

if options[:json]
  puts JSON.pretty_generate(
    "stage2_class_candidates" => class_candidates.size,
    "route_roots_extracted" => roots.size,
    "stage3_removed" => stage3_removed.size,
    "stage3_survivors" => class_candidates.size - stage3_removed.size,
    "stage4_demoted" => stage4_removed.size,
    "stage4_survivors" => survivors.size,
    "survivors" => survivors,
    "demoted" => stage4_removed,
    "route_removed" => stage3_removed
  )
  exit 0
end

puts "project:                  #{project}"
puts "class/module candidates:  #{class_candidates.size}"
puts "route roots extracted:    #{roots.size} (rough)"
puts "stage 3 (route roots):    -#{stage3_removed.size}  ->  #{class_candidates.size - stage3_removed.size}"
puts "stage 4 (dynamic):        -#{stage4_removed.size}  ->  #{survivors.size}"
puts "  by reason: " + stage4_removed.group_by { |c| c["reason"] }.transform_values(&:size).inspect
if options[:list]
  puts
  puts "-- survivors (#{survivors.size}) --"
  survivors.each_with_index do |c, i|
    puts format("%3d  %-60s %s", i + 1, c["name"], Array(c["paths"]).first)
  end
end
