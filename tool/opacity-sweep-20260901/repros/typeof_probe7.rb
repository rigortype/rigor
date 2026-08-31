class Al
  def translate(name)
    "x-#{name}"
  end
  alias_method :t, :translate
end

Al.new.t("a")
Al.new.translate("a")
