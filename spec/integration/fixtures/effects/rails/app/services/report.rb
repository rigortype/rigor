class Report
  def cached
    Rails.cache.fetch("report")
  end

  def environment
    Rails.env
  end

  def translated
    I18n.t("report.title")
  end

  def stamp
    Time.current
  end

  def raw
    ActiveRecord::Base.connection.execute("UPDATE users SET name = 'x'")
  end
end
