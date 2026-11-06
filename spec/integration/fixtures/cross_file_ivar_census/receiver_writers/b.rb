class RA
  def initialize
    @w = nil
    @y = nil
    @z = nil
    @v = nil
    @u = nil
    @x = nil
  end

  def get_w = @w.upcase
  def get_y = @y.upcase
  def get_z = @z.upcase
  def get_v = @v.upcase
  def get_u = @u.upcase
  def get_x = @x.upcase
  def typed_v = assert_type("String?", @v)
end

RB.attr_writer :w
