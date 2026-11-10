# 05 — Declaration mutants: which declarations does any run actually check?

A runtime witness proves something only if the checker looked. RBS's runtime checker silently skips
some declarations: in a field trial on rgl 0.6.7, a return declared on the module `RGL::Graph` and
implemented in the including class `DirectedAdjacencyGraph` was never checked, so a run of rgl's own
test suite under `rbs/test/setup` passed although those declarations went unchecked. The same holds
for a single witness: a clean exit means nothing until a deliberately broken declaration makes the same
run fail.

This is mutation testing aimed at the declarations instead of the code. Break one declaration at a
time, re-run the witnesses, and see whether the run notices:

- **killed** — the run reports a type error the clean run did not. The declaration is checked.
- **survived** — no new type error. Nothing you ran checks this declaration: no call reaches it, or
  the checker does not hook it. Treat it as unverified at runtime, whatever the suite reported.

Two operators cover the questions this skill asks:

| Operator | Mutation | A survivor means |
| --- | --- | --- |
| `bot` | the return type becomes `bot`, which no value inhabits | no run checks this declaration at all |
| `drop-nil` | a `T?` return becomes `T` | no run reaches the `nil` arm, so the `?` has no witness |

`void` returns are skipped: the checker does not compare them, by design.

A built-in command for this is proposed in #3072; until it exists, the script below is the procedure.

## Running it

The script below needs only the `rbs` gem. Give it the directory of declarations under review and the
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

# Break each RBS return declaration in turn and check whether a witness command notices.
#
#   ruby rbs_decl_mutants.rb SIG_DIR -- COMMAND...
#
# COMMAND must run the witnesses under rbs/test/setup (RBS_TEST_TARGET set) and read the declarations
# from $RBS_TEST_OPT, which this script sets to `-I <mutant dir>` plus any RBS_DECL_MUTANTS_EXTRA_OPT.
# Two operators: `bot` replaces a return with a type nothing inhabits (does anything check this
# declaration at all?); `drop-nil` turns `T?` into `T` (does a witness reach the nil arm?).
# A mutant is killed when the run prints a type error the clean run did not.
require "rbs"
require "fileutils"
require "open3"
require "tmpdir"

sig_dir = ARGV.shift
ARGV.shift if ARGV.first == "--"
command = ARGV
abort "usage: ruby rbs_decl_mutants.rb SIG_DIR -- COMMAND..." if sig_dir.nil? || command.empty?

TYPE_ERROR = /\[[^\]]+\] (?:Return|Argument|Block|BlockArgument|BlockReturn)TypeError[^\n]*/
files = Dir[File.join(sig_dir, "**", "*.rbs")].reject { |f| f.include?("/_test/") }
extra = ENV.fetch("RBS_DECL_MUTANTS_EXTRA_OPT", "")

def run(command, dir, extra)
  out, = Open3.capture2e({ "RBS_TEST_OPT" => "-I #{dir} #{extra}".strip }, *command, stdin_data: "")
  out.scan(TYPE_ERROR).uniq
end

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
      sites << [file, ret.location, "bot", label]
      sites << [file, ret.location, ret.type.to_s, "#{label} drop-nil"] if ret.is_a?(RBS::Types::Optional)
    end
  end
end
files.each { |f| RBS::Parser.parse_signature(File.read(f))[2].each { |d| collect.call(d, [], f) } }

Dir.mktmpdir("rbs-decl-mutants") do |tmp|
  clean = File.join(tmp, "clean")
  FileUtils.cp_r(sig_dir, clean)
  FileUtils.rm_rf(Dir[File.join(clean, "**", "_test")])
  baseline = run(command, clean, extra)
  warn "clean run already reports #{baseline.size} type error(s); they are ignored" unless baseline.empty?

  survivors = sites.reject do |file, loc, replacement, label|
    dir = File.join(tmp, "mutant")
    FileUtils.rm_rf(dir)
    FileUtils.cp_r(clean, dir)
    target = File.join(dir, file.delete_prefix(sig_dir).delete_prefix("/"))
    src = File.binread(file)
    File.binwrite(target, src.byteslice(0, loc.start_pos) + replacement + src.byteslice(loc.end_pos..))
    killed = !(run(command, dir, extra) - baseline).empty?
    puts "#{killed ? 'killed  ' : 'SURVIVED'} #{label}"
    killed
  end
  puts "#{sites.size} mutants, #{sites.size - survivors.size} killed, #{survivors.size} survived"
end
```

## Reading the result

- Report every survivor in the write-up as "unchecked at runtime", with the operator. It is not a
  defect in the declaration; it is the limit of what your evidence covers.
- A `bot` survivor on a method your witnesses call is the checker's blind spot. Redeclare the member on
  the class that defines the method (where that is also a correct declaration), or rely on
  documentation for it and say so.
- A `drop-nil` survivor means the `?` rests on documentation alone. If the documentation does not
  mention `nil` either, the `?` has no evidence: re-examine it.
- A killed mutant on a "say less" change is the negative control that change needs.

On rgl (61 mutants, 53 killed), the survivors were four returns declared on the module `RGL::Graph`
and implemented in including classes, a `?` on `Edge::DirectedEdge#<=>` that no witness exercised, and
three more (two singleton `.[]` constructors and an `untyped` reader) whose cause was not investigated.
