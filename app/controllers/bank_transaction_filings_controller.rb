# Filing a bank transaction as the Deposits, Spends and Refunds it was (ADR 0009), and taking that back. The form is opened from the
# Unfiled list or from the bank transaction's Account, and saving, ignoring or cancelling goes back there (ReturnsToOrigin).
class BankTransactionFilingsController < ApplicationController
  include BankTransactionScoped

  before_action :require_unfiled, only: %i[ new create ]

  # Starts as the bank transaction would be filed with nothing changed: its date and description, and all of its amount.
  def new
    @entry = Budget::Filing::Entry.new(bank_transaction: @bank_transaction, drafts: [ Budget::Filing::Draft.for(@bank_transaction) ])
  end

  # Files it as the records the form has, all or none. What's wrong comes back on the form, with everything as it was entered.
  def create
    @entry = Budget::Filing::Entry.new(bank_transaction: @bank_transaction, drafts: draft_params)

    if Budget::Filing.new(Current.budget).file([ @entry ])
      redirect_to origin_path, notice: "Bank transaction filed."
    else
      render :new, status: :unprocessable_content
    end
  end

  # Un-files it: the records it was filed as are deleted, and it's unfiled again.
  def destroy
    @bank_transaction.unfile
    redirect_to origin_path, status: :see_other, notice: "Bank transaction unfiled."
  rescue Budget::BankTransaction::Refused => refusal
    redirect_to origin_path, status: :see_other, alert: refusal.message
  end

  private
    # Only an unfiled bank transaction can be filed: one that isn't says why, where the form was opened from.
    def require_unfiled
      redirect_to origin_path, alert: Budget::BankTransaction::FILING_REFUSALS.fetch(@bank_transaction.state) unless @bank_transaction.unfiled?
    end

    # The records the form sent, in the order it numbered them, as drafts. A form sends its records as a hash from each one's
    # number, such as `records[0][kind]`. The kind, the envelope and the rest are only what's asked: Filing looks the envelope up
    # in the budget's own, and refuses what isn't right.
    def draft_params
      records = params.expect(filing: [ records: [ [ :kind, :envelope_id, :description, :date, :month, :amount, :notes ] ] ])[:records]

      records.to_h.sort_by { |number, _| number.to_i }.map { |_, record| Budget::Filing::Draft.new(record) }
    end
end
