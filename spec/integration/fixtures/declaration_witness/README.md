# Declaration-fact witness fixtures

`spec/support/declaration_witness.rb` **executes** every Ruby file here in a child process, under the Ruby running
the suite, and compares what Ruby records with Rigor's discovery tables (`spec/rigor/declaration_facts/witness_spec.rb`).
Write a fixture that loads cleanly in a few seconds: one that raises, exits early or runs past the time limit fails
the spec as a broken fixture. Keep it free of I/O, network and global side effects beyond the declarations it tests.

Each fixture is a positive control or reproduces one filed bug. A bug fixture stays `pending` with its issue link
until the bug is fixed, and a non-pending example pins its exact violations today.
