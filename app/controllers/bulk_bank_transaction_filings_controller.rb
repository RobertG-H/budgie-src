# File selected and Un-file selected: the bank transactions ticked on the Bank transactions page, all or none. Filing puts each in one envelope, as a Spend
# for money out and a Refund for money in, with the bank's own description and date (BulkBankTransactions, Budget::BankTransaction::Selection), and it asks
# nothing first because un-filing takes it back. Un-filing deletes the records they were filed as, so it's asked first, on the button.
class BulkBankTransactionFilingsController < ApplicationController
  include BulkBankTransactions

  def create
    return refuse("Choose an envelope to file them to.") if params[:envelope_id].blank? && selected_ids.any?

    act_on_selection do |chosen|
      "Filed #{kinds_filed(chosen)} to #{Current.budget.envelopes.find(params[:envelope_id]).name}." if chosen.file_to(params[:envelope_id])
    end
  end

  def destroy
    act_on_selection do |chosen|
      "#{helpers.pluralize(chosen.count, "bank transaction")} unfiled." if chosen.unfile
    end
  end

  private
    # "38 Spends and 2 Refunds": what filing them made, in the words the button said it would.
    def kinds_filed(chosen)
      helpers.bulk_filing_kinds(chosen.bank_transactions)
    end
end
