# ADR-0: Foundation and Core Architecture of Rigor

## Status

Accepted

## Context

As the Ruby ecosystem matures with tools like Sorbet, Steep, and RBS, there is a growing need for a static analyzer that maximizes **type inference** and **practical gradual typing**. Existing tools often require heavy type annotations within the application code, which introduces noise for both human developers and AI coding assistants (LLMs). Furthermore, Ruby's dynamic nature and metaprogramming remain significant hurdles for traditional type checkers.

We need a next-generation static analysis tool that prioritizes AI-native purity, zero runtime overhead, high-performance caching, and practical resolution of metaprogramming through a robust plugin system. 

## Decisions

We will build a new static analysis tool named **Rigor** ("Rigorous Inference for Ruby"), designed with the following core principles:

### 1. AI-Native Purity & Zero Runtime Dependency

* **No Explicit Types in App Code:** Rigor will not require explicit type signatures (like inline annotations or custom DSLs) in application code. This keeps the codebase 100% pure Ruby, reducing noise for LLMs and maintaining idiomatic readability.
* **Zero Runtime Overhead:** Rigor functions strictly as a development dependency. It will not hook into the application at runtime.

### 2. Hybrid Type Resolution & Advanced Type System

* **Powerful Inference First:** The core engine relies on deep Control Flow Analysis (CFA) and Data Flow Analysis to deduce types.
* **Advanced Types:** Rigor will support Union Types, Literal Types (e.g., `1`, `"str"`), and Virtual/Refined Types (e.g., `non-empty-string`, `positive-int`).
* **External Dependencies via RBS:** Standard gem types will be resolved using the existing RBS ecosystem.
* **`RBS::Extended`:** To express advanced types not yet supported by standard RBS, we will introduce an extended syntax using comments (e.g., `# @rigor return: non-empty-string` or local type assertions like `#: @rigor var config: { mode: :fast | :safe }`).

### 3. PHPStan-like Plugin Architecture

* Ruby's metaprogramming (e.g., Rails' `ActiveRecord`, dynamic `method_missing`) will be handled purely by **external plugins**.
* **Virtual Protocols:** Rigor will provide an extension API (similar to PHPStan) using virtual "Protocols" or type classes. This allows Rigor itself to statically verify that plugins correctly implement required hooks (e.g., Dynamic Method Resolution, Return Type Inference).

### 4. High-Performance Caching & DX

* Rigor will implement aggressive AST and dependency graph caching.
* The primary goal is to provide instantaneous feedback during coding. We will prioritize a robust **CLI experience first**, deferring LSP (Language Server Protocol) integration to a later phase.
* **Smart Initialization:** `rigor init` will analyze `Gemfile.lock` to automatically suggest and configure the necessary plugins (e.g., Rails, RSpec) and project directories.

### 5. MVP Target (CLI)

The Minimum Viable Product will focus on foundational Control Flow Analysis to catch potential `NoMethodError`s resulting from union types.

**MVP Example Scope:**

```ruby
# Rigor CFA must track branches and infer `v` as `Integer | String` (1 | "str")
if rand == 0
  v = 1
else
  v = "str"
end

# Rigor must report an error: Integer (1) does not respond to `upcase`
p v.upcase 
```

## Consequences

* **Positive:** Application code remains clean and AI-friendly. The plugin architecture keeps the core engine small, maintainable, and highly performant. The CLI-first approach ensures the inference engine is deeply tested and reliable before dealing with asynchronous editor states.
* **Negative/Risks:** Implementing a robust Control Flow Graph (CFG) from scratch (likely using `Prism` or `SyntaxTree`) requires significant upfront engineering effort. Building the plugin ecosystem will require community adoption or maintaining core framework plugins (like Rails) ourselves initially.
