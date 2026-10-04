# Ignoring a bank transaction, which Budgie won't file, such as a card payment between a person's own accounts, and un-ignoring it.
# Pairing transfers between Accounts is out of scope, so both sides are ignored separately.
class BankTransactionIgnoresController < ApplicationController
  include BankTransactionScoped
  include FilingFormParams

  # Ignores it, and makes an Ignore rule from it if "Always file like this" was ticked, in the same database transaction. Ignore is a
  # button on the filing form, which sends the whole form, so a rule that's refused comes back as the form, as it was.
  def create
    drafts = submitted_drafts
    @offer = filing_rule_offer(records: drafts.size)

    if @offer.make? ? @offer.ignore : @bank_transaction.ignore
      redirect_to origin_path, notice: "Bank transaction ignored."
    else
      @entry = Budget::Filing::Entry.new(bank_transaction: @bank_transaction, drafts: drafts)
      render "bank_transaction_filings/new", status: :unprocessable_content
    end
  rescue Budget::BankTransaction::Refused => refusal
    redirect_to origin_path, alert: refusal.message
  end

  def destroy
    @bank_transaction.unignore
    redirect_to origin_path, status: :see_other, notice: "Bank transaction un-ignored."
  rescue Budget::BankTransaction::Refused => refusal
    redirect_to origin_path, status: :see_other, alert: refusal.message
  end
end
