# Who the signed-in person is: their name and email, how they sign in, and their budget's currency. It's read-only for now. It needs no
# budget, so it's there during setup too.
class ProfilesController < ApplicationController
  allow_missing_budget

  def show
    @user = Current.user
    @identities = @user.identities.order(:created_at, :id)
    @budget = Current.budget
  end
end
