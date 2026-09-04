/* Fixture C source for spec/docs/c_effects_raises_gate_spec.rb — deliberately shaped like a real
 * data/builtins/ruby_core/*.yml row pair, one broken and one correct, to prove the gate's scan can
 * both fail (on `broken`) and stay quiet (on `fine`) without needing a real references/ruby checkout.
 */

static VALUE
fake_broken(VALUE self)
{
    rb_raise(rb_eRuntimeError, "deliberately broken fixture row");
    return Qnil;
}

static VALUE
fake_fine(VALUE self)
{
    return Qnil;
}
