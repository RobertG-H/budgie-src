# Ignore selected and Un-ignore selected: the bank transactions ticked on the Bank transactions page, all or none (BulkBankTransactions). An Ignore a person
# chose isn't to review, as one at a time isn't.
class BulkBankTransactionIgnoresController < ApplicationController
  include BulkBankTransactions

  def create
    act_on_selection do |chosen|
      "#{helpers.pluralize(chosen.count, "bank transaction")} ignored." if chosen.ignore
    end
  end

  def destroy
    act_on_selection do |chosen|
      "#{helpers.pluralize(chosen.count, "bank transaction")} un-ignored." if chosen.unignore
    end
  end
end
