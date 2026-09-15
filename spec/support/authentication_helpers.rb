module AuthenticationHelpers
  # Signs the user in for the rest of a request spec without going through a provider.
  # Returns their new Session.
  def sign_in_as(user)
    user.sessions.create!.tap do |session|
      cookie_jar = ActionDispatch::TestRequest.create.cookie_jar
      cookie_jar.signed[:session_id] = session.id
      cookies["session_id"] = cookie_jar[:session_id]
    end
  end
end

RSpec.configure do |config|
  config.include AuthenticationHelpers, type: :request
end
