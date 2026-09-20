# frozen_string_literal: true

# Gates `bin/rigor-worktree`'s verification of a `--with-references` copy.
#
# The bug this pins: `git worktree add` materializes an EMPTY placeholder directory for every
# registered submodule path, so `cp -R SRC DST` copied the checkout INTO it and produced
# `references/ruby/ruby`. The script's own check was `git rev-parse --verify HEAD`, which passes on
# the nested copy — the `.git` pointer is written at the correct level and resolves against the
# shared module store regardless of where the contents landed. So did `ls references/`. The result
# was a worktree where `spec/docs/c_effects_raises_gate_spec.rb` SKIPped while `make docs-check`
# reported green: the silent SKIP `--with-references` exists to prevent.
#
# The fix is two-sided, and only the second side is gateable here: the copy clears the placeholder
# first, and the verification compares the copy's contents against the source instead of asking git
# a question that cannot come back wrong. This file holds the second side — a verification that
# cannot fail is the defect, so the fail path is what gets asserted, the same standard
# `spec/docs/c_effects_raises_gate_spec.rb` holds its own fixture arm to.
#
# It sources the two functions out of the real script rather than restating them, so a rewrite that
# weakens the check is caught rather than mirrored.

require "spec_helper"
require "fileutils"
require "shellwords"
require "tmpdir"

module RigorWorktreeReferenceClone
  SCRIPT = File.expand_path("../../bin/rigor-worktree", __dir__)

  module_function

  # The named shell function's full text, lifted from the script as shipped.
  def function_source(name)
    body = File.read(SCRIPT)[/^#{Regexp.escape(name)}\(\).*?\n\}\n/m]
    raise "bin/rigor-worktree no longer defines #{name}()" unless body

    body
  end

  # True when the script's own verification accepts `dst` as a faithful copy of `src`.
  def verifies?(src, dst)
    snippet = <<~SH
      set -uo pipefail
      #{function_source('reference_entries')}
      #{function_source('verify_reference_clone')}
      verify_reference_clone #{Shellwords.escape(src)} #{Shellwords.escape(dst)}
    SH
    Bundler.with_unbundled_env do
      system("bash", "-c", snippet, out: File::NULL, err: File::NULL)
    end
  end

  # A stand-in `references/<name>` checkout: a real git repository, so the `rev-parse HEAD` arm of
  # the verification is exercised for what it is still worth.
  def build_source(dir)
    FileUtils.mkdir_p(File.join(dir, "include"))
    File.write(File.join(dir, "object.c"), "/* stand-in for the file the C-effects gate opens */\n")
    File.write(File.join(dir, ".dir-locals.el"), ";; a dotfile at the top level\n")
    File.write(File.join(dir, "include/ruby.h"), "/* nested content */\n")
    git(dir, "init", "--quiet")
    git(dir, "add", "--all")
    git(dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "--quiet", "-m", "seed")
    dir
  end

  def git(dir, *args)
    Bundler.with_unbundled_env do
      system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) ||
        raise("git #{args.join(' ')} failed in #{dir}")
    end
  end

  # The copy the fixed script makes: contents at the path itself.
  def copy_faithfully(src, dst)
    FileUtils.mkdir_p(dst)
    FileUtils.cp_r(Dir.glob(File.join(src, "*")) + Dir.glob(File.join(src, ".[!.]*")), dst)
    dst
  end

  # The copy the broken script made: `cp -R SRC DST` onto the placeholder `git worktree add` left.
  def copy_into_placeholder(src, dst)
    FileUtils.mkdir_p(dst)
    FileUtils.cp_r(src, dst)
    dst
  end
end

RSpec.describe "bin/rigor-worktree reference-clone verification" do
  let(:tmp) { Dir.mktmpdir("rigor-worktree-refs") }
  let(:source) { RigorWorktreeReferenceClone.build_source(File.join(tmp, "main", "references", "ruby")) }

  after { FileUtils.remove_entry(tmp, true) }

  it "accepts a copy whose contents landed at the path itself" do
    dst = RigorWorktreeReferenceClone.copy_faithfully(source, File.join(tmp, "good", "references", "ruby"))

    expect(File.file?(File.join(dst, "object.c"))).to be(true)
    expect(RigorWorktreeReferenceClone.verifies?(source, dst)).to be(true)
  end

  it "rejects a copy nested one level deep, which `rev-parse HEAD` and `ls` both report as correct" do
    dst = RigorWorktreeReferenceClone.copy_into_placeholder(source, File.join(tmp, "bad", "references", "ruby"))
    File.write(File.join(dst, ".git"), "gitdir: #{File.join(source, '.git')}\n")

    # The two cheap looks that made this bug invisible, asserted as the non-discriminators they are.
    expect(Dir.children(dst).reject { |e| e == ".git" }).to eq(["ruby"])
    expect(RigorWorktreeReferenceClone.git(dst, "rev-parse", "--verify", "--quiet", "HEAD")).to be(true)
    expect(File.file?(File.join(dst, "object.c"))).to be(false)

    expect(RigorWorktreeReferenceClone.verifies?(source, dst)).to be(false)
  end

  it "accepts a sparse checkout, whose working tree holds less than its own HEAD lists" do
    # `references/phpstan` and `references/TypeScript-Website` are sparse, so a verification that
    # probed a name out of `git ls-tree HEAD` failed on both. The source and the copy agree; HEAD
    # is not the reference point.
    FileUtils.rm_rf(File.join(source, "include"))
    dst = RigorWorktreeReferenceClone.copy_faithfully(source, File.join(tmp, "sparse", "references", "phpstan"))

    expect(RigorWorktreeReferenceClone.verifies?(source, dst)).to be(true)
  end

  it "rejects a copy that is missing part of the source" do
    dst = RigorWorktreeReferenceClone.copy_faithfully(source, File.join(tmp, "partial", "references", "ruby"))
    FileUtils.rm_rf(File.join(dst, "include"))

    expect(RigorWorktreeReferenceClone.verifies?(source, dst)).to be(false)
  end
end
