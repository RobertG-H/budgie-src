# Mark reviewed, for the bank transactions ticked in the To review state (ADR 0017). Unlike the others it's lenient: it marks the ones that are still to
# review and says how many, and one that isn't any more, such as one un-filed in another tab, is skipped and doesn't stop the rest.
class BulkBankTransactionReviewsController < ApplicationController
  include BulkBankTransactions

  def create
    act_on_selection do |chosen|
      reviewed = chosen.mark_reviewed
      skipped = chosen.count - reviewed
      message = "#{helpers.pluralize(reviewed, "bank transaction")} marked reviewed."
      skipped.positive? ? "#{message} #{helpers.pluralize(skipped, "other")} #{skipped == 1 ? "wasn't" : "weren't"} to review any more." : message
    end
  end
end
