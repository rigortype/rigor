# A Sidekiq worker: no base class at all, only an include. The plugin's rows key on the marker module,
# which is what #456 taught the plugin-fact ancestry to walk.
class NotifyWorker
  include Sidekiq::Job

  def perform(id)
    User.find(id)
  end
end
