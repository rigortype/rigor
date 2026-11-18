require "rigor/testing"
include Rigor::Testing

# Issue #3337, review round 4 — a `Binding` or a string `eval` can rebind
# any local of its frame by name, with no write node for the walk to see.
# A frame that holds such a call keeps every loop store on the join with
# its continuation binding. Each method is a frame of its own; Ruby 4.0.5
# answers `[nil, nil]` for every one but the last.

def loop_store_clear(frame)
  frame.local_variable_set(:s, nil)
end

def loop_store_by_binding
  out = []
  i = 0
  while i < 2
    s = "a"
    binding.local_variable_set(:s, nil)
    out << s
    i += 1
  end
  assert_type("Array[String?]", out)
  out
end

def loop_store_by_eval
  out = []
  i = 0
  while i < 2
    s = "a"
    eval("s = nil")
    out << s
    i += 1
  end
  assert_type("Array[String?]", out)
  out
end

def loop_store_by_helper
  out = []
  i = 0
  while i < 2
    s = "a"
    loop_store_clear(binding)
    out << s
    i += 1
  end
  assert_type("Array[String?]", out)
  out
end

def loop_store_by_proc_binding
  out = []
  i = 0
  while i < 2
    s = "a"
    proc { 1 }.binding.local_variable_set(:s, nil)
    out << s
    i += 1
  end
  assert_type("Array[String?]", out)
  out
end

def loop_store_by_binding_eval
  out = []
  i = 0
  while i < 2
    s = "a"
    binding.eval("s = nil")
    out << s
    i += 1
  end
  assert_type("Array[String?]", out)
  out
end

def loop_store_by_earlier_binding
  out = []
  i = 0
  s = nil
  held = binding
  while i < 2
    s = "a"
    held.local_variable_set(:s, nil)
    out << s
    i += 1
  end
  assert_type("Array[String?]", out)
  out
end

def loop_store_by_instance_eval
  out = []
  i = 0
  while i < 2
    s = "a"
    instance_eval("s = nil")
    out << s
    i += 1
  end
  assert_type("Array[String?]", out)
  out
end

def loop_store_by_class_eval
  out = []
  i = 0
  while i < 2
    s = "a"
    Object.class_eval("s = nil")
    out << s
    i += 1
  end
  assert_type("Array[String?]", out)
  out
end

def loop_store_by_module_eval
  out = []
  i = 0
  while i < 2
    s = "a"
    Kernel.module_eval("s = nil")
    out << s
    i += 1
  end
  assert_type("Array[String?]", out)
  out
end

# The block form of `instance_eval` hands over no source text, and its block
# writes no local: `["a", "a"]`, read where the store runs.
def loop_store_block_eval
  out = []
  i = 0
  while i < 2
    s = ENV.fetch("X", "a")
    instance_eval { 1 }
    out << s
    i += 1
  end
  assert_type("Array[String]", out)
  out
end

# A frame with none of these still reads the store where it runs:
# `["a", "a"]`.
def loop_store_plain_frame
  out = []
  i = 0
  while i < 2
    s = ENV.fetch("X", "a")
    out << s
    i += 1
  end
  assert_type("Array[String]", out)
  out
end
