// Discovery's pure and filesystem-reading parts: the mise / asdf pin reader,
// the pin rules, the project root and the document-selector glob.

import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";

import {
  displayCommand,
  findPin,
  lockfileFor,
  multilineStringAfter,
  pinnedBundleGemfile,
  projectRoot,
  rigortypePin,
  rootGlob,
  shouldManageFolder,
  tomlToolsNameRigortype,
} from "../src/discovery";
import { addFolder, stub } from "./vscode-stub";
import { Sandbox, lockfile, sandbox, write } from "./helpers";

let sb: Sandbox;

beforeEach(() => {
  stub.reset();
  sb = sandbox();
});

afterEach(() => sb.dispose());

describe("tomlToolsNameRigortype", () => {
  const pins = (text: string) => tomlToolsNameRigortype(text);

  it("reads the [tools] table: bare, quoted and gem: keys", () => {
    assert.equal(pins('[tools]\nrigortype = "0.4.7"\n'), true);
    assert.equal(pins('[tools]\n"gem:rigortype" = "0.4.7"\n'), true);
    assert.equal(pins("[tools]\n'gem:rigortype' = '0.4.7'\n"), true);
    assert.equal(pins('[tools]\nruby = "4.0"\n  rigortype="latest"\n'), true);
    assert.equal(pins('[ tools ]  # the tools\nrigortype = "1"\n'), true);
  });

  it("mismatched quotes around the key are not a pin", () => {
    assert.equal(pins("[tools]\n\"gem:rigortype' = \"1\"\n"), false);
    assert.equal(pins("[tools]\n'rigortype\" = \"1\"\n"), false);
  });

  it("reads a [tools.\"gem:rigortype\"] table", () => {
    assert.equal(pins('[tools."gem:rigortype"]\nversion = "0.4.7"\n'), true);
    assert.equal(pins('[tools.rigortype]\nversion = "0.4.7"\n'), true);
    assert.equal(pins('[tools.ruby]\nversion = "4.0"\n'), false);
  });

  it("reads a root dotted key and a root inline table", () => {
    assert.equal(pins('tools."gem:rigortype" = "0.4.7"\n'), true);
    assert.equal(pins('tools = { "gem:rigortype" = "0.4.7" }\n'), true);
    assert.equal(pins('tools = { ruby = "4.0", rigortype = "0.4.7" }\n'), true);
    assert.equal(pins('tools = { ruby = "4.0" }\n'), false);
  });

  it("a dotted key under another table is not a pin", () => {
    assert.equal(pins('[env]\ntools."gem:rigortype" = "0.4.7"\n'), false);
  });

  it("[env] and other tables are not pins", () => {
    assert.equal(pins('[env]\nrigortype = "x"\n'), false);
    assert.equal(pins('[tools]\n[env]\nrigortype = "x"\n'), false);
    assert.equal(pins('[settings]\nrigortype = 1\n'), false);
    assert.equal(pins('rigortype = "x"\n'), false);
  });

  it("a key that only contains the name is not a pin", () => {
    assert.equal(pins('[tools]\nrigortype-extras = "1"\n'), false);
    assert.equal(pins('[tools]\nmyrigortype = "1"\n'), false);
    assert.equal(pins('[tools]\n"gem:rigortype-extras" = "1"\n'), false);
  });

  it("a comment mentioning rigortype is not a pin", () => {
    assert.equal(pins('[tools]\n# rigortype = "1"\n'), false);
  });

  it("reads CRLF files", () => {
    assert.equal(pins('[tools]\r\nrigortype = "1"\r\n'), true);
  });

  describe("multi-line strings", () => {
    it("skips lines inside a \"\"\" or ''' string", () => {
      assert.equal(pins('[tools]\nnote = """\nrigortype = "x"\n"""\n'), false);
      assert.equal(pins("[tools]\nnote = '''\nrigortype = \"x\"\n'''\n"), false);
      assert.equal(pins('note = """\n[tools]\n"""\nrigortype = "x"\n'), false);
    });

    it("reads past the closing delimiter", () => {
      assert.equal(pins('[tools]\nnote = """\nx\n"""\nrigortype = "x"\n'), true);
    });

    it("tracks the two delimiters apart", () => {
      // A """ inside a ''' string is text: the string is still open.
      assert.equal(pins("[tools]\nnote = '''\n\"\"\"\nrigortype = \"x\"\n'''\n"), false);
      assert.equal(pins("[tools]\nnote = '''\n\"\"\"\n'''\nrigortype = \"x\"\n"), true);
      assert.equal(pins("[tools]\nnote = \"\"\"\n'''\nrigortype = \"x\"\n\"\"\"\n"), false);
    });

    it("a delimiter inside a single-line string or after # opens nothing", () => {
      assert.equal(pins("x = '\"\"\"'\n[tools]\nrigortype = \"1\"\n"), true);
      assert.equal(pins("x = \"'''\"\n[tools]\nrigortype = \"1\"\n"), true);
      assert.equal(pins('[tools]\n# """\nrigortype = "1"\n'), true);
      assert.equal(pins('[tools] # """\nrigortype = "1"\n'), true);
      assert.equal(pins('[tools]\nx = 1 # \'\'\'\nrigortype = "1"\n'), true);
    });

    it("a backslash escapes in \"...\" and \"\"\"...\"\"\" but not in '''...'''", () => {
      // `\"` does not close the string, so `"""` after it is a closer only if
      // three quotes follow; here two quotes follow the escape.
      assert.equal(multilineStringAfter('x = """abc\\"""', undefined), '"""');
      assert.equal(multilineStringAfter("x = '''abc\\'''", undefined), undefined);
      // An escaped backslash does not escape the quote after it.
      assert.equal(multilineStringAfter('x = "a\\\\" # """', undefined), undefined);
      assert.equal(multilineStringAfter('x = "a\\"" """', undefined), '"""');
      assert.equal(pins('[tools]\nx = """a\\"""\nrigortype = "1"\n"""\n'), false);
    });

    it("continues a string open at the start of the line", () => {
      assert.equal(multilineStringAfter('still text """', '"""'), undefined);
      assert.equal(multilineStringAfter("still text '''", "'''"), undefined);
      assert.equal(multilineStringAfter('still text """', "'''"), "'''");
    });
  });
});

describe("findPin and rigortypePin", () => {
  it("a Gemfile.lock pin is scope lock; skipLocks looks past it", () => {
    write(path.join(sb.project, "Gemfile.lock"), lockfile("0.4.7"));
    assert.deepEqual(findPin(sb.project), { file: path.join(sb.project, "Gemfile.lock"), scope: "lock" });
    assert.equal(rigortypePin(sb.project), path.join(sb.project, "Gemfile.lock"));
    assert.equal(findPin(sb.project, { skipLocks: true }), undefined);
  });

  it(".github/rigor/Gemfile.lock is a lock pin", () => {
    const lock = write(path.join(sb.project, ".github", "rigor", "Gemfile.lock"), lockfile("0.4.7"));
    assert.deepEqual(findPin(sb.project), { file: lock, scope: "lock" });
  });

  it("a project lock beats a mise file", () => {
    write(path.join(sb.project, "mise.toml"), '[tools]\nrigortype = "1"\n');
    write(path.join(sb.project, "gems.locked"), lockfile("0.4.7"));
    assert.equal(findPin(sb.project)?.scope, "lock");
  });

  describe(".tool-versions", () => {
    const pinned = (text: string) => {
      write(path.join(sb.project, ".tool-versions"), text);
      return findPin(sb.project)?.scope;
    };

    it("names rigortype or gem:rigortype with a version", () => {
      assert.equal(pinned("ruby 4.0.1\nrigortype 0.4.7\n"), "project");
      assert.equal(pinned("gem:rigortype 0.4.7\n"), "project");
      assert.equal(pinned("  rigortype\t0.4.7\n"), "project");
    });

    it("is no pin without a version, in a comment, or for another name", () => {
      assert.equal(pinned("rigortype\n"), undefined);
      assert.equal(pinned("# rigortype 0.4.7\n"), undefined);
      assert.equal(pinned("rigortype-extras 1\n"), undefined);
      assert.equal(pinned("ruby 4.0.1 # rigortype 1\n"), undefined);
    });
  });

  it("a mise file in a directory above the project (below home) is a project pin", () => {
    const root = path.join(sb.home, "work", "app");
    write(path.join(sb.home, "work", ".mise.toml"), '[tools]\nrigortype = "1"\n');
    assert.deepEqual(findPin(root), { file: path.join(sb.home, "work", ".mise.toml"), scope: "project" });
  });

  it("finds the other mise file names", () => {
    for (const name of [
      "mise.local.toml",
      ".mise/config.toml",
      ".config/mise.toml",
      ".config/mise/config.toml",
      ".config/mise/conf.d/extra.toml",
    ]) {
      const file = write(path.join(sb.project, name), '[tools]\nrigortype = "1"\n');
      assert.deepEqual(findPin(sb.project), { file, scope: "project" }, name);
      write(file, "");
    }
  });

  it("MISE_ENV adds mise.<env>.toml", () => {
    const file = write(path.join(sb.project, "mise.ci.toml"), '[tools]\nrigortype = "1"\n');
    assert.equal(findPin(sb.project), undefined);
    process.env.MISE_ENV = "dev, ci";
    assert.deepEqual(findPin(sb.project), { file, scope: "project" });
  });

  describe("global pins", () => {
    const installed = () =>
      write(path.join(process.env.MISE_DATA_DIR!, "installs", "gem-rigortype", "0.4.7", "bin", "rigor"));

    it("count only while a rigortype is installed through mise or asdf", () => {
      const global = write(path.join(sb.home, ".tool-versions"), "rigortype 0.4.7\n");
      assert.equal(findPin(sb.project), undefined);
      installed();
      assert.deepEqual(findPin(sb.project), { file: global, scope: "global" });
    });

    it("an empty installs directory is not installed", () => {
      write(path.join(sb.home, ".tool-versions"), "rigortype 0.4.7\n");
      fs.mkdirSync(path.join(process.env.MISE_DATA_DIR!, "installs", "gem-rigortype"), { recursive: true });
      assert.equal(findPin(sb.project), undefined);
    });

    it("asdf's installs directory counts too", () => {
      const global = write(path.join(sb.home, ".tool-versions"), "rigortype 0.4.7\n");
      write(path.join(process.env.ASDF_DATA_DIR!, "installs", "rigortype", "0.4.7", "x"));
      assert.equal(findPin(sb.project)?.file, global);
    });

    it("mise's global config, conf.d, MISE_CONFIG_DIR and MISE_GLOBAL_CONFIG_FILE are read", () => {
      installed();
      const config = write(path.join(sb.home, ".config", "mise", "config.toml"), '[tools]\nrigortype = "1"\n');
      assert.deepEqual(findPin(sb.project), { file: config, scope: "global" });
      write(config, "");

      const confD = write(path.join(sb.home, ".config", "mise", "conf.d", "a.toml"), '[tools]\nrigortype = "1"\n');
      assert.equal(findPin(sb.project)?.file, confD);
      write(confD, "");

      process.env.MISE_CONFIG_DIR = path.join(sb.dir, "cfg");
      const moved = write(path.join(sb.dir, "cfg", "config.toml"), '[tools]\nrigortype = "1"\n');
      assert.equal(findPin(sb.project)?.file, moved);
      write(moved, "");

      process.env.MISE_GLOBAL_CONFIG_FILE = path.join(sb.dir, "g.toml");
      write(process.env.MISE_GLOBAL_CONFIG_FILE, '[tools]\nrigortype = "1"\n');
      assert.equal(findPin(sb.project)?.file, process.env.MISE_GLOBAL_CONFIG_FILE);
    });

    it("a mise file in the home directory or above it is global, not the project's", () => {
      write(path.join(sb.home, "mise.toml"), '[tools]\nrigortype = "1"\n');
      write(path.join(sb.dir, ".tool-versions"), "rigortype 1\n");
      assert.equal(findPin(sb.project), undefined);
      write(path.join(process.env.MISE_DATA_DIR!, "installs", "rigortype", "1", "x"));
      assert.equal(findPin(sb.project)?.scope, "global");
    });

    it("a project pin beats a global one", () => {
      installed();
      write(path.join(sb.home, ".tool-versions"), "rigortype 0.4.7\n");
      const proj = write(path.join(sb.project, ".tool-versions"), "rigortype 0.5.0\n");
      assert.deepEqual(findPin(sb.project), { file: proj, scope: "project" });
    });
  });
});

describe("projectRoot", () => {
  const rootFor = (rootDir: string | undefined) => {
    stub.reset();
    if (rootDir !== undefined) {
      stub.set("rigor.rootDir", rootDir);
    }
    return projectRoot(addFolder(sb.project));
  };

  it("is the folder when rootDir is empty or unset", () => {
    assert.equal(rootFor(undefined), sb.project);
    assert.equal(rootFor("  "), sb.project);
  });

  it("resolves a relative subdirectory, trimmed", () => {
    assert.equal(rootFor("api"), path.join(sb.project, "api"));
    assert.equal(rootFor(" api/sub "), path.join(sb.project, "api", "sub"));
    assert.equal(rootFor("a/../b"), path.join(sb.project, "b"));
    assert.equal(rootFor("./"), sb.project);
  });

  it("accepts a directory whose name starts with two dots", () => {
    assert.equal(rootFor("..foo"), path.join(sb.project, "..foo"));
  });

  it("rejects .., anything leading out, and an absolute path", () => {
    assert.equal(rootFor(".."), undefined);
    assert.equal(rootFor("../sibling"), undefined);
    assert.equal(rootFor("a/../.."), undefined);
    assert.equal(rootFor(path.join(sb.project, "api")), undefined);
    assert.equal(rootFor("/etc"), undefined);
  });
});

describe("pinnedBundleGemfile", () => {
  const forValue = (value: string | undefined) => {
    stub.reset();
    if (value !== undefined) {
      stub.set("rigor.server.bundleGemfile", value);
    }
    return pinnedBundleGemfile(addFolder(sb.project), sb.project);
  };

  it("defaults to .github/rigor/Gemfile", () => {
    assert.deepEqual(forValue(undefined), {
      gemfile: path.join(sb.project, ".github", "rigor", "Gemfile"),
      explicit: false,
    });
  });

  it("accepts a path inside the root, including a ..foo directory", () => {
    assert.deepEqual(forValue("ci/Gemfile"), { gemfile: path.join(sb.project, "ci", "Gemfile"), explicit: true });
    assert.equal(forValue("..foo/Gemfile").rejected, undefined);
  });

  it("rejects the root itself, a path leaving it and an absolute path", () => {
    assert.equal(forValue(".").rejected, ".");
    assert.equal(forValue("../x/Gemfile").rejected, "../x/Gemfile");
    assert.equal(forValue(path.join(sb.project, "Gemfile")).rejected, path.join(sb.project, "Gemfile"));
  });
});

describe("lockfileFor", () => {
  it("gems.rb locks to gems.locked; any other Gemfile to <name>.lock", () => {
    assert.equal(lockfileFor("/p/gems.rb"), "/p/gems.locked");
    assert.equal(lockfileFor("/p/Gemfile"), "/p/Gemfile.lock");
    assert.equal(lockfileFor("/p/ci.gemfile"), "/p/ci.gemfile.lock");
  });
});

describe("shouldManageFolder", () => {
  const manage = () => shouldManageFolder(addFolder(sb.project));

  it("needs positive evidence", () => {
    assert.equal(manage(), false);
  });

  it("is on for a config file, a pinning lockfile, a pinned bundle or an explicit path", () => {
    write(path.join(sb.project, ".rigor.dist.yml"));
    assert.equal(manage(), true);
    stub.reset();
    fs.rmSync(path.join(sb.project, ".rigor.dist.yml"));
    write(path.join(sb.project, "Gemfile.lock"), lockfile("0.4.7"));
    assert.equal(manage(), true);
    stub.reset();
    fs.rmSync(path.join(sb.project, "Gemfile.lock"));
    write(path.join(sb.project, ".github", "rigor", "Gemfile.lock"), lockfile("0.4.7"));
    assert.equal(manage(), true);
    stub.reset();
    fs.rmSync(path.join(sb.project, ".github"), { recursive: true });
    stub.set("rigor.server.path", "/x/rigor");
    assert.equal(manage(), true);
  });

  it("a quoted explicit path counts, and a quoted empty string is unset", () => {
    stub.set("rigor.server.path", '"/x/rigor"');
    assert.equal(manage(), true);
    stub.reset();
    stub.set("rigor.server.path", '""');
    assert.equal(manage(), false);
  });

  it("rigor.enable false turns it off, and a rejected rootDir too", () => {
    write(path.join(sb.project, ".rigor.yml"));
    stub.set("rigor.enable", false);
    assert.equal(manage(), false);
    stub.reset();
    stub.set("rigor.rootDir", "..");
    assert.equal(manage(), false);
  });
});

describe("rootGlob", () => {
  it("matches every file below the root", () => {
    assert.equal(rootGlob("/work/app"), "/work/app/**/*");
  });

  it("uses forward slashes", () => {
    assert.equal(rootGlob("C:\\Users\\me\\app"), "C:/Users/me/app/**/*");
  });

  it("makes * ? [ ] literal with character classes", () => {
    assert.equal(rootGlob("/w/a[1]"), "/w/a[[]1[]]/**/*");
    assert.equal(rootGlob("/w/a*b?c"), "/w/a[*]b[?]c/**/*");
  });

  it("replaces a brace with ?, which VS Code would otherwise read as a group", () => {
    assert.equal(rootGlob("/w/{a,b}"), "/w/?a,b?/**/*");
    assert.equal(rootGlob("/w/a}b"), "/w/a?b/**/*");
  });

  it("escapes brackets before braces are replaced", () => {
    assert.equal(rootGlob("/w/[{x}]"), "/w/[[]?x?[]]/**/*");
  });
});

describe("displayCommand", () => {
  it("shows a pinned bundle's BUNDLE_GEMFILE first, and only for that kind", () => {
    const pinned = {
      kind: "pinned-bundle" as const,
      command: "bundle",
      prefixArgs: ["exec", "rigor"],
      env: { BUNDLE_GEMFILE: "/p/Gemfile" },
    };
    assert.equal(displayCommand(pinned, pinned.prefixArgs), "BUNDLE_GEMFILE=/p/Gemfile bundle exec rigor");
    assert.equal(displayCommand({ ...pinned, kind: "bundler" }, pinned.prefixArgs), "bundle exec rigor");
  });
});
