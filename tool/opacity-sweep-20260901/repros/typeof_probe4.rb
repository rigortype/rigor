# alias_method and attr chains
class I18nish
  def translate(name, vars = {})
    "x-#{name}-#{vars.size}"
  end
  alias t translate

  def deep
    42
  end
  alias also_deep deep
end

I18nish.new.t('a')
I18nish.new.also_deep
I18nish.new.translate('a')
