# 05 — Declaration mutants: which declarations does any run actually check?

A runtime witness proves something only if the checker looked. RBS's runtime checker silently skips
some declarations: it checks a method only against a declaration on the same class or module that
defines the method in Ruby, so a declaration inherited from a module or superclass by a class that
defines or overrides the method is skipped (unless it carries `%a{rbs:test:target}`). In a field trial
on rgl 0.6.7, rgl's own test suite ran under `rbs/test/setup` with one expected failure while several
declarations of that kind were never checked. A single witness has the same problem: a clean exit means
nothing until a deliberately broken declaration makes the same run fail.

This is mutation testing aimed at the declarations instead of the code. Break one method return at a
time, re-run the witnesses, and see whether the run notices:

- **killed** — the run reports a type error, naming the mutated method, that the clean run did not.
  The return is checked.
- **SURVIVED** — no such error. Nothing you ran checks this return: no call reaches it, or the checker
  skips it. Treat it as unverified at runtime, whatever the suite reported.
- **ERROR** — the mutant does not load. Nothing was learned; fix the script or the declarations.
- **UNKNOWN** — the clean run already reports a type error on this method. Fix that first.

| Operator | Mutation | A survivor means |
| --- | --- | --- |
| `bot` | the return type becomes `bot`, which no value inhabits | no run checks this return at all |
| `drop-nil` | a `T?` return becomes `(T)` | no run reaches the `nil` arm, so the `?` has no witness |

`void` returns are skipped (the checker does not compare them, by design), and so is `drop-nil` on
`untyped?` (`untyped` already admits `nil`). Parameters, blocks and `attr_*` declarations are not mutated:
the pass says nothing about them.

A built-in command for this is proposed in #3072; until it exists, the script below is the procedure.

## Running it

The script needs only the `rbs` gem. Give it the directory of declarations under review and the
command that runs your witnesses — a witness script, the project's test suite, or a collection entry's
`_test/` — under `rbs/test/setup` with `RBS_TEST_TARGET` set. The script sets `RBS_TEST_OPT` to the
mutant directory itself; pass any further `-I` / `-r` options in `RBS_DECL_MUTANTS_EXTRA_OPT`. Save it as
`rbs_decl_mutants.rb` outside the project.

```sh
RBS_DECL_MUTANTS_EXTRA_OPT='-I ../deps-sig' ruby rbs_decl_mutants.rb sig -- ./run-witnesses.sh
```

`run-witnesses.sh` is whatever runs your witnesses, for example:

```sh
#!/bin/sh
RBS_TEST_TARGET='MyGem::*' ruby -I lib -I test -rrbs/test/setup -e 'Dir["test/*_test.rb"].each { |f| require_relative File.expand_path(f) }'
```

Each mutant is one full run, so the pass costs the command's runtime times the number of non-`void`
returns (rgl: 61 mutants, about 70 seconds). It runs the library's code, so the safety rules for a
witness apply: for a gem not already in the user's bundle, use a container or VM or ask first.

```ruby
# frozen_string_literal: true

# Break each RBS method return in turn and check whether a witness command notices.
#
#   ruby rbs_decl_mutants.rb SIG_DIR -- COMMAND...
#
# COMMAND runs the witnesses under rbs/test/setup (RBS_TEST_TARGET set) and must read declarations from
# $RBS_TEST_OPT, which this script sets to `-I <mutant dir>` plus RBS_DECL_MUTANTS_EXTRA_OPT.
# Operators: `bot` (nothing inhabits it: is this declaration checked at all?) and `drop-nil` (`T?` -> `T`:
# does any witness reach the nil arm?). A mutant is killed only by a type error that names the mutated
# method and that the clean run did not report; a mutant that does not load is an ERROR, never a survivor;
# a method the clean run already fails on is UNKNOWN.
require "rbs"
require "fileutils"
require "open3"
require "set"
require "shellwords"
require "tmpdir"

Encoding.default_external = Encoding::UTF_8
sig_dir = File.expand_path(ARGV.shift.to_s)
ARGV.shift if ARGV.first == "--"
command = ARGV
abort "usage: ruby rbs_decl_mutants.rb SIG_DIR -- COMMAND..." if !File.directory?(sig_dir) || command.empty?
extra = ENV.fetch("RBS_DECL_MUTANTS_EXTRA_OPT", "")

# `[Owner#name] KindError: ...` -> ["Owner#name", "KindError"]; the value after the colon is dropped
# because it carries object addresses and sampled elements that differ from run to run.
ERROR_TAG = /^.*?\[(.+?)\] (\w+Error):/
def type_errors(out) = out.each_line.filter_map { |l| (m = l.match(ERROR_TAG)) && [m[1], m[2]] }.to_set

def run(command, dir, extra)
  out, = Open3.capture2e({ "RBS_TEST_OPT" => "-I #{dir} #{extra}".strip }, *command, stdin_data: "")
  out
end

# Load the mutant the way rbs/test/setup will, so a mutant that does not load is reported, not run.
def loads?(dir, extra)
  loader = RBS::EnvironmentLoader.new
  loader.add(path: Pathname(dir))
  Shellwords.split(extra).each_slice(2) do |flag, value|
    flag == "-I" ? loader.add(path: Pathname(value)) : (flag == "-r" && loader.add(library: value, version: nil))
  end
  env = RBS::Environment.from_loader(loader).resolve_type_names
  RBS::DefinitionBuilder.new(env: env)
  true
rescue StandardError => e
  warn "  load error: #{e.class}: #{e.message.lines.first}"
  false
end

files = Dir[File.join(sig_dir, "**", "*.rbs")].reject { |f| f.split(File::SEPARATOR).include?("_test") }
sites = []
collect = lambda do |decl, ns, file|
  case decl
  when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module
    decl.members.each { |m| collect.call(m, ns + [decl.name.to_s.delete_prefix("::")], file) }
  when RBS::AST::Members::MethodDefinition
    sep = decl.kind == :singleton ? "." : "#"
    decl.overloads.each_with_index do |overload, index|
      ret = overload.method_type.type.return_type
      next if ret.location.nil? || ret.is_a?(RBS::Types::Bases::Void)
      label = "#{ns.join('::')}#{sep}#{decl.name} (overload #{index}, #{ret})"
      tag_suffix = "#{sep}#{decl.name}"
      sites << [file, ret.location, "bot", label, tag_suffix]
      next unless ret.is_a?(RBS::Types::Optional) && !ret.type.is_a?(RBS::Types::Bases::Any)
      sites << [file, ret.location, "(#{ret.type})", "#{label} drop-nil", tag_suffix]
    end
  end
end
files.each { |f| RBS::Parser.parse_signature(File.read(f, encoding: "UTF-8"))[2].each { |d| collect.call(d, [], f) } }

Dir.mktmpdir("rbs-decl-mutants") do |tmp|
  clean = File.join(tmp, "clean")
  FileUtils.cp_r(sig_dir, clean)
  FileUtils.rm_rf(Dir[File.join(clean, "**", "_test")])
  abort "the clean declarations do not load" unless loads?(clean, extra)
  baseline = type_errors(run(command, clean, extra))
  warn "clean run reports #{baseline.size} type error(s); those tags are ignored" unless baseline.empty?

  tally = Hash.new(0)
  sites.each do |file, loc, replacement, label, tag_suffix|
    dir = File.join(tmp, "mutant")
    FileUtils.rm_rf(dir)
    FileUtils.cp_r(clean, dir)
    target = File.join(dir, file.delete_prefix(sig_dir).delete_prefix(File::SEPARATOR))
    src = File.read(file, encoding: "UTF-8") # RBS locations are character offsets
    File.write(target, src[0...loc.start_pos] + replacement + src[loc.end_pos..])
    verdict =
      if baseline.any? { |tag, _kind| tag.end_with?(tag_suffix) }
        "UNKNOWN" # the clean run already fails on this method; fix that first
      elsif !loads?(dir, extra)
        "ERROR"
      else
        fresh = type_errors(run(command, dir, extra)) - baseline
        fresh.any? { |tag, _kind| tag.end_with?(tag_suffix) } ? "killed" : "SURVIVED"
      end
    tally[verdict] += 1
    puts "#{verdict.ljust(8)} #{label}"
  end
  puts "#{sites.size} mutants: #{tally['killed']} killed, #{tally['SURVIVED']} survived, " \
       "#{tally['ERROR']} did not load, #{tally['UNKNOWN']} already failing in the clean run"
end
```

## Reading the result

- Report every survivor in the write-up as "unchecked at runtime", with the operator. It is not a
  defect in the declaration; it is the limit of what your evidence covers.
- A `bot` survivor on a method your witnesses call is the checker's skip rule at work. Redeclare the
  member on the class that defines the method (where that is also a correct declaration), add
  `%a{rbs:test:target}` to the inherited declaration, or rely on documentation for it and say so.
- A `bot` survivor on a method nothing calls is a missing witness: add a call, or say so.
- A `drop-nil` survivor means the `?` rests on documentation alone. If the documentation does not
  mention `nil` either, the `?` has no evidence: re-examine it.
- A killed mutant on a "say less" change is the negative control that change needs.

On the rgl draft the pass reported 61 mutants: 55 killed, 6 survived. Three survivors were the skip
rule (`Graph#directed?`, `#has_vertex?`, `#has_edge?`, declared on the module `Graph` and overridden in
classes); `Graph#to_s` was never called; `Graph#eql?` is reached in rgl's tests only through its `==`
alias (not investigated further); and the `?` on `Edge::DirectedEdge#<=>` had no witness.
