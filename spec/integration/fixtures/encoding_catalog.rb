require "rigor/testing"
include Rigor::Testing

# Methods unlocked by extracting the Encoding catalog from
# `Init_Encoding` in `references/ruby/encoding.c`. Encoding
# constants such as `Encoding::UTF_8` resolve through the RBS
# loader to `Nominal[Encoding]`; the catalog's RBS-tier sigs
# (`name -> String`, `dummy? -> bool`, ...) then route every
# instance / singleton method call to a precise nominal answer.
# Mutating singleton setters (`default_external=`,
# `default_internal=`) and registry-walking lookups
# (`Encoding.find`, `Encoding.list`, `Encoding.aliases`,
# `Encoding.name_list`) are blocklisted so a hypothetical
# future `Constant<Encoding>` carrier cannot fold them
# against the live process registry.

e = Encoding::UTF_8
assert_type("Encoding", e)

# Catalog-classified `:leaf` instance methods route through
# the RBS sig on a `Nominal[Encoding]` receiver.
assert_type("String", e.name)
assert_type("Array[String]", e.names)
assert_type("false | true", e.dummy?)
assert_type("false | true", e.ascii_compatible?)
assert_type("String", e.inspect)

# Singleton lookups against the global registry. The catalog
# blocklists these so a `Constant<Encoding>`-class receiver
# cannot fold the lookup against the analyzer process's
# registry; the RBS-tier answer is what every caller gets.
assert_type("Encoding | nil", Encoding.find("UTF-8"))
assert_type("Array[Encoding]", Encoding.list)
assert_type("Hash[String, String]", Encoding.aliases)
assert_type("Array[String]", Encoding.name_list)

# Singleton getters for the global default encodings. These
# are blocklisted because the matching setters mutate the same
# global slots.
assert_type("Encoding", Encoding.default_external)
assert_type("Encoding | nil", Encoding.default_internal)
