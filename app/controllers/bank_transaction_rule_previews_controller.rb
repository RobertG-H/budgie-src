# What "Always file like this" would do with the text as it stands on the filing form: whether it would update a rule that's there, and
# how many other unfiled bank transactions it would file or ignore. It's a Turbo Frame that the form asks for, with the form's own
# fields, as the text is edited, so that a rule that's too broad is seen before it's made (ADR 0012). Nothing is changed.
class BankTransactionRulePreviewsController < ApplicationController
  include BankTransactionScoped
  include FilingFormParams

  def show
    @offer = filing_rule_offer
  end
end
