# A project-only declaration of a class Ruby's own libraries define opens that class's surface

- **PR:** [#2264](https://github.com/rigortype/rigor/pull/2264)
- **Issue:** [#2174](https://github.com/rigortype/rigor/issues/2174)
- **Class:** open-choice
- **Precedent:** [#1982](https://github.com/rigortype/rigor/pull/1982)
- **Decided:** 2026-10-21

## Background

`class Matrix` reopened with one `#:`-annotated method, and no `matrix` signatures loaded, gave `Matrix` a declaration holding only that method, so `Matrix.identity(2)` reported `call.undefined-method` on correct code. The issue suggested declining "when the name is a known stdlib library's class", but `Matrix` is not in the `rbs` gem's `stdlib/` tree at all (it is a gem bundled with Ruby), so the issue's own example needed a wider definition of "a library Ruby ships", and nothing said whether a `sig/` reopen counts too.

## Options and trade-offs

- Decline only for names the `rbs` gem's `stdlib/` tree declares. This is exact, but it misses the issue's own `Matrix` and every other bundled gem.
- Camelize Ruby's installed gem names into constants (`matrix` → `Matrix`). `MissingGemConstantIndex` rejects this kind of name guessing: it breaks on irregular names.
- Take root constants from the libraries' own files, as listed under Decision. This costs about 0.1 s, paid lazily and only once a project-only class reaches a verdict.
- Decline for every class whose only declarations are the project's own. This is broadest, and it loses every typo report on an rbs-inline-annotated project class, the main thing such annotations buy.

## Decision

Take the third option. A class opens (`CheckRules#unbounded_receiver_surface?`, the mechanism #1982 used for `OpenStruct`) only when all three conditions below hold.

- **Every RBS declaration of the class is the project's own.** It is either RBS synthesized from the project's source (rbs-inline) or a file under the user's configured `signature_paths:` (the auto-detected `sig/` when none is configured). A plugin's `sig/`, a gem-shipped `sig/`, an rbs collection and a `data/gem_overlay/` directory are the library's own declarations, so a class any of them declares stays checked.
- **The class's root constant is declared by a library Ruby ships.** Exactly three sources are read: the `.rbs` files of every library in the `rbs` gem's `stdlib/` tree, loaded or not; the top-level declarations of each `.rb` file directly in `RbConfig::CONFIG["rubylibdir"]`; and the entry file of each gem Ruby 4.0 bundles. Those gems are the fixed list `RequiredFeatures::BUNDLED_GEMS`, looked up under `Gem.default_dir/gems`; any other gem installed there is not read.
- **The project's source `require`s a feature of that library.** `RequiredFeatures.features_of` now keeps every required feature whose first path segment Ruby ships, and the first segments must match (`require "net/http"` matches `Net` through the stdlib `net-http` library). This gate keeps a project's own `class Vector` checked unless the project requires `matrix`.

Methods the project's declaration lists stay checked. Three costs are accepted:

- A project class that shares a required library's root name loses its `call.undefined-method` reports, and a signature it only inherits stops deciding `call.wrong-arity` and `call.argument-type-mismatch`.
- A shipped required feature counts (`RequiredFeatures.relevant`) only when its library declares a root that the project's source or signatures declare a class or module under, read textually from `class` / `module` headers. Only such a feature enters the incremental snapshot's fingerprint and the language server's environment key. Adding or removing it re-checks the whole project; any other stdlib `require` re-checks only the file it is in. Such features never become library tokens, so the RBS environment's cache key is unchanged.
- Gems locked in the project's Gemfile but not shipped with Ruby are left out, as a follow-up.

## To undo

Remove the `ruby_library_reopen?` arm from `CheckRules#unbounded_receiver_surface?`. `RbsLoader#ruby_library_reopen?`, `Environment::RubyLibraryRoots`, the loader's `project_signature_paths:` and `required_features:` inputs, and the shipped-feature half of `RequiredFeatures.features_of` then have no reader and can go with it.
