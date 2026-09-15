class Session < ApplicationRecord
  INACTIVITY_LIMIT = 30.days
  ACTIVITY_UPDATE_INTERVAL = 1.hour

  belongs_to :user

  attribute :last_active_at, default: -> { Time.current }

  def expired?
    last_active_at.before?(INACTIVITY_LIMIT.ago)
  end

  # Writes at most once per interval, so an active session doesn't cost an update on every request.
  def record_activity
    touch(:last_active_at) if last_active_at.before?(ACTIVITY_UPDATE_INTERVAL.ago)
  end
end
