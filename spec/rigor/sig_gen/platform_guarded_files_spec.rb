# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Rigor::SigGen::PlatformGuardedFiles do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def write_fixture(rel_path, contents)
    full = File.join(tmpdir, rel_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, contents)
    full
  end

  def guarded_set(*paths)
    described_class.call(paths)
  end

  it "marks a file required only under a RUBY_ENGINE guard" do
    entry = write_fixture("lib/app.rb", <<~RUBY)
      if RUBY_ENGINE == "truffleruby"
        require_relative "app/truffleruby"
      end
    RUBY
    stub_file = write_fixture("lib/app/truffleruby.rb", "module App; end\n")

    expect(guarded_set(entry, stub_file)).to include(File.expand_path(stub_file))
  end

  it "marks a file required through `require` when an ancestor directory resolves it" do
    entry = write_fixture("lib/app.rb", <<~RUBY)
      require "app/backend" if RUBY_PLATFORM =~ /java/
    RUBY
    backend = write_fixture("lib/app/backend.rb", "module App; end\n")

    expect(guarded_set(entry, backend)).to include(File.expand_path(backend))
  end

  it "does not mark a file an unguarded require also reaches" do
    guarded = write_fixture("lib/a.rb", 'require_relative "shared" if RUBY_ENGINE == "x"')
    plain = write_fixture("lib/b.rb", 'require_relative "shared"')
    shared = write_fixture("lib/shared.rb", "module Shared; end\n")

    expect(guarded_set(guarded, plain, shared)).not_to include(File.expand_path(shared))
  end

  it "marks a helper a guarded file requires unconditionally — the guard is transitive" do
    entry = write_fixture("lib/app.rb", <<~RUBY)
      require_relative "app/truffleruby" if RUBY_ENGINE == "truffleruby"
    RUBY
    stub_file = write_fixture("lib/app/truffleruby.rb", 'require_relative "helper"')
    helper = write_fixture("lib/app/helper.rb", "module App; end\n")

    guarded = guarded_set(entry, stub_file, helper)

    expect(guarded).to include(File.expand_path(stub_file), File.expand_path(helper))
  end

  it "does not mark a file with no scanned require site" do
    lone = write_fixture("lib/lone.rb", "module Lone; end\n")

    expect(guarded_set(lone)).to be_empty
  end

  it "does not treat a namespaced RUBY_ENGINE as the platform constant" do
    entry = write_fixture("lib/app.rb", <<~RUBY)
      if MyApp::RUBY_ENGINE == "x"
        require_relative "app/backend"
      end
    RUBY
    backend = write_fixture("lib/app/backend.rb", "module App; end\n")

    expect(guarded_set(entry, backend)).to be_empty
  end

  it "marks a file required under a compound guard that also reads RUBY_VERSION" do
    entry = write_fixture("lib/app.rb", <<~RUBY)
      if RUBY_ENGINE == "truffleruby" && RUBY_VERSION >= "3.0"
        require_relative "app/truffleruby"
      end
    RUBY
    stub_file = write_fixture("lib/app/truffleruby.rb", "module App; end\n")

    expect(guarded_set(entry, stub_file)).to include(File.expand_path(stub_file))
  end

  it "marks a file required under a guard whose other `||` operand reads ENV" do
    entry = write_fixture("lib/app.rb", <<~RUBY)
      require_relative "app/truffleruby" if RUBY_ENGINE == "truffleruby" || ENV["FORCE_STUB"]
    RUBY
    stub_file = write_fixture("lib/app/truffleruby.rb", "module App; end\n")

    expect(guarded_set(entry, stub_file)).to include(File.expand_path(stub_file))
  end

  it "does not treat RUBY_VERSION alone as a platform guard" do
    entry = write_fixture("lib/app.rb", <<~RUBY)
      require_relative "app/newer" if RUBY_VERSION >= "3.0"
    RUBY
    newer = write_fixture("lib/app/newer.rb", "module App; end\n")

    expect(guarded_set(entry, newer)).to be_empty
  end

  it "marks a require under a `case` on RUBY_ENGINE" do
    entry = write_fixture("lib/app.rb", <<~RUBY)
      case RUBY_ENGINE
      when "truffleruby"
        require_relative "app/backend"
      end
    RUBY
    backend = write_fixture("lib/app/backend.rb", "module App; end\n")

    expect(guarded_set(entry, backend)).to include(File.expand_path(backend))
  end

  it "returns an empty set when a scanned file does not parse — its require edges are unknowable" do
    broken = write_fixture("lib/broken.rb", "def broken(")
    entry = write_fixture("lib/app.rb", 'require_relative "app/backend" if RUBY_ENGINE == "x"')
    backend = write_fixture("lib/app/backend.rb", "module App; end\n")

    expect(guarded_set(broken, entry, backend)).to be_empty
  end

  it "ignores require features that resolve outside the scanned set" do
    entry = write_fixture("lib/app.rb", 'require "some_gem/file" if RUBY_ENGINE == "x"')
    backend = write_fixture("lib/app/backend.rb", "module App; end\n")

    expect(guarded_set(entry, backend)).to be_empty
  end
end
