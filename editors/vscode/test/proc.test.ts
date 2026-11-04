// Shell quoting for the cmd.exe that `shell: true` interposes on Windows.

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { shellArg, shellInvocation } from "../src/proc";
import { withPlatform } from "./helpers";

describe("shellArg", () => {
  it("passes everything through on POSIX", async () => {
    await withPlatform("linux", () => {
      assert.equal(shellArg("a b & c"), "a b & c");
      assert.equal(shellArg(""), "");
    });
  });

  it("on Windows leaves a plain argument alone", async () => {
    await withPlatform("win32", () => {
      assert.equal(shellArg("--format=json"), "--format=json");
      assert.equal(shellArg("C:\\Rigor\\bin\\rigor.cmd"), "C:\\Rigor\\bin\\rigor.cmd");
    });
  });

  it("on Windows quotes whitespace, an empty string and every cmd metacharacter", async () => {
    await withPlatform("win32", () => {
      assert.equal(shellArg("C:\\Users\\First Last\\rigor.cmd"), '"C:\\Users\\First Last\\rigor.cmd"');
      assert.equal(shellArg(""), '""');
      for (const c of ["&", "|", "^", "<", ">", "(", ")", "%", "!"]) {
        assert.equal(shellArg(`a${c}b`), `"a${c}b"`, c);
      }
    });
  });

  it("on Windows doubles an embedded quote", async () => {
    await withPlatform("win32", () => {
      assert.equal(shellArg('say "hi"'), '"say ""hi"""');
    });
  });
});

describe("shellInvocation", () => {
  it("passes the vector through untouched without a shell", async () => {
    await withPlatform("win32", () => {
      assert.deepEqual(shellInvocation("C:\\a b\\ruby.exe", ["x y"], false), {
        command: "C:\\a b\\ruby.exe",
        args: ["x y"],
      });
    });
  });

  it("quotes the command and every argument for a shell on Windows", async () => {
    await withPlatform("win32", () => {
      assert.deepEqual(shellInvocation("C:\\a b\\rigor.cmd", ["check", "--config=my file.yml"], true), {
        command: '"C:\\a b\\rigor.cmd"',
        args: ["check", '"--config=my file.yml"'],
      });
    });
  });

  it("with a shell on POSIX quotes nothing", async () => {
    await withPlatform("linux", () => {
      assert.deepEqual(shellInvocation("a b", ["c d"], true), { command: "a b", args: ["c d"] });
    });
  });
});
