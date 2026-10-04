class Current < ActiveSupport::CurrentAttributes
  attribute :session
  delegate :user, to: :session, allow_nil: true

  # The one way controllers and views find the budget. For now it's the signed-in user's, if they have one.
  def budget
    user&.budget
  end
end
