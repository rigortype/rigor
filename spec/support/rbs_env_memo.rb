# frozen_string_literal: true

require "digest"
require "rigor/environment/rbs_loader"

# Process-level reuse of identical `RBS::Environment` builds, for the spec suite only.
#
# Measured over a full `make test-binpacker` run, `RbsLoader.build_env_for` was called 1809 times for
# 674.9 s — about 53 % of the suite's 1281 s of worker time. Only 240 distinct environments exist across
# the whole suite, and 1487 of those builds (561.9 s) re-built an environment the *same worker process* had
# already built. Three environment contents alone accounted for 1085 builds.
#
# The repeats are not a spec-hygiene failure that could be fixed file by file — they are spread over more
# than fifty spec files and arise two ways at once. An example that passes `cache_store: nil` has no cache
# to consult, and an example whose sig files land in a fresh `Dir.mktmpdir` gets a different
# `Cache::RbsDescriptor` from an identical neighbour, because that descriptor keys on `(path, sha)`. Both
# produce byte-identical environments from byte-identical inputs.
#
# So the reuse is keyed on the INPUT CONTENT — library list, signature-file bytes, virtual RBS bytes —
# rather than on paths, which is what lets it collapse the repeats the cache descriptor cannot see.
#
# == Why sharing the instance is safe
#
# `build_env_for` is a pure function of the inputs digested here, and nothing outside `RbsLoader` mutates
# the environment it returns: every `add_source` / decl insertion in `lib/` is inside the build itself.
# Sharing one instance across examples is also not new — `Cache::Store`'s in-process memo already hands the
# same `RBS::Environment` to every example whose descriptor matches, which is most of the suite.
#
# == Where it is NOT safe, and how to opt out
#
# What memoisation does change is the *act* of building: a repeat no longer re-parses, so it no longer
# re-emits the build-time warnings (quarantined signature files, virtual-RBS collisions) that a handful of
# specs assert on. Any example that exercises building rather than the built result must tag itself
# `:fresh_rbs_env` and gets an unmemoised build.
#
# `RIGOR_SPEC_NO_ENV_MEMO=1` disables the memo suite-wide. That is the control arm: the suite must be green
# both ways, and a difference between them is this file's bug, not a flake.
module RbsEnvMemo
  # An environment holds a few tens of MB, so the cache is a small LRU rather than unbounded. It costs
  # almost nothing to keep it small: simulated against the census above, a cap of 1 already avoids 515.6 s
  # of the 561.9 s available and a cap of 3 avoids 544.1 s, because each worker process is dominated by one
  # or two environments. The median worker sees exactly one distinct environment; the busiest sees 51.
  CAPACITY = 3

  class << self
    def enabled?
      return false if ENV["RIGOR_SPEC_NO_ENV_MEMO"]

      !RSpec.current_example&.metadata&.fetch(:fresh_rbs_env, false)
    end

    # @return [::RBS::Environment, nil] the cached environment for `key`, promoting it to most-recent.
    def fetch(key)
      value = cache.delete(key)
      cache[key] = value unless value.nil?
      value
    end

    def store(key, value)
      cache.delete(key)
      cache[key] = value
      cache.shift while cache.size > CAPACITY
      value
    end

    def digest(libraries, signature_paths, virtual_rbs, deferred_signature_paths = [])
      parts = ["lib\0#{Array(libraries).map(&:to_s).sort.join(',')}"]
      # Issue #610 — which paths are DEFERRED changes the built env (a deferred file stands down against a
      # colliding generic arity), so it is an input like any other. Digesting the path list is enough: the
      # files themselves are already digested below, since every deferred path is also a signature path.
      parts << "deferred\0#{Array(deferred_signature_paths).map(&:to_s).sort.join(',')}"

      Array(signature_paths).map(&:to_s).sort.each do |root|
        signature_files(root).each { |path| parts << "sig\0#{path}\0#{file_digest(path)}" }
      end

      Array(virtual_rbs).map { |name, content| "virt\0#{name}\0#{content}" }.sort.each { |p| parts << p }

      Digest::SHA256.hexdigest(parts.join("\n"))
    end

    private

    # Ruby hashes keep insertion order, so `shift` drops the least recently used entry.
    def cache
      @cache ||= {}
    end

    # The path is part of the digest alongside its content: two sig roots holding the same bytes under
    # different names are different inputs to `add_project_signatures`, which reports diagnostics against
    # the file name it read.
    def signature_files(root)
      return [root] if File.file?(root)

      Dir.glob(File.join(root, "**", "*.rbs"))
    end

    # Re-hashing every signature file on each build would give back part of what the memo saves, so a file's
    # digest is cached against its identity. `size` and `mtime` are what a spec rewriting a fixture in place
    # changes; both move together with the content in every shape the suite produces.
    def file_digest(path)
      stat = File.stat(path)
      identity = [path, stat.size, stat.mtime.to_r]
      file_digests[identity] ||= Digest::SHA256.file(path).hexdigest
    rescue SystemCallError
      "unreadable"
    end

    def file_digests
      @file_digests ||= {}
    end
  end

  # Prepended onto the loader's singleton so it wraps `build_env_for` for every caller, including
  # `Cache::RbsEnvironment.compute` on a cache miss.
  module Interception
    def build_env_for(libraries:, signature_paths:, virtual_rbs: [], deferred_signature_paths: [])
      return super unless RbsEnvMemo.enabled?

      key = RbsEnvMemo.digest(libraries, signature_paths, virtual_rbs, deferred_signature_paths)
      cached = RbsEnvMemo.fetch(key)
      return cached if cached

      RbsEnvMemo.store(key, super)
    end
  end
end

Rigor::Environment::RbsLoader.singleton_class.prepend(RbsEnvMemo::Interception)

RSpec.configure do |config|
  # Two files take building itself as their subject rather than consuming a built environment, so they are
  # exempted wholesale instead of example by example.
  #
  # `rbs_loader_spec.rb` asserts on what a build emits — the notice naming a quarantined signature file, the
  # virtual-RBS collision report — which a memo hit would not re-emit. `rbs_environment_spec.rb` asserts on
  # how MANY times the cache producer computed (`have_received(:build_env_for).once`), and the memo sits in
  # front of the partial double, so a hit would never reach it.
  #
  # Both pass today either way, because each example feeds the loader signature content no other example
  # uses and so never hits the memo. That is luck, not a contract: the assertions are about the act of
  # building, and this tag is what keeps them measuring it.
  config.define_derived_metadata(
    file_path: Regexp.union(
      %r{/spec/rigor/environment/rbs_loader_spec\.rb\z},
      %r{/spec/rigor/cache/rbs_environment_spec\.rb\z}
    )
  ) do |meta|
    meta[:fresh_rbs_env] = true
  end
end
