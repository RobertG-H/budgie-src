# The bank's record of money moving in or out of an Account, before Budgie has filed it as Deposits, Spends and Refunds, or
# ignored it. Its amount is signed: positive is money in and negative is money out, never 0 (ADR 0009).
#
# It belongs to its budget through its Account, as a Spend does through its envelope, so it has no budget of its own. It's
# read-only to the person: bank transactions come from an Import and go with it, or with their Account's budget.
#
# What says which row it is in its Account (ADR 0010) is its content key and occurrence, which are written once, when the row
# is made, and never again, because they record how it first looked. The description is as the bank gave it, so it can be
# updated in place later, and `normalized_description` is kept by the database to follow it, for a Filing rule or a Guess to
# read.
class Budget::BankTransaction < ApplicationRecord
  belongs_to :account
  belongs_to :import

  normalizes :description, with: ->(description) { description.strip }

  before_validation :set_content_key_and_occurrence, on: :create

  validates :description, presence: true
  validates :date, presence: true
  validates :amount, money: true
  validate :amount_is_not_zero

  scope :newest_first, -> { order(date: :desc, id: :desc) }

  # The key of a row: a digest of its Account, date, signed amount and description, with the description trimmed, its
  # whitespace collapsed and its case folded, so a row that differs in nothing a person would notice is the same row.
  def self.content_key(account_id:, date:, amount:, description:)
    Digest::SHA256.hexdigest([ account_id, date.iso8601, format("%.2f", amount), normalize_description(description) ].join("\u001F"))
  end

  def self.normalize_description(description)
    description.squish.downcase(:fold)
  end

  private
    # A row made one at a time is the next occurrence of its key. An Import numbers all of its rows itself, in one go.
    def set_content_key_and_occurrence
      return if content_key.present? || account_id.nil? || date.nil? || amount.nil? || description.blank?

      self.content_key = self.class.content_key(account_id: account_id, date: date, amount: amount, description: description)
      self.occurrence ||= account.bank_transactions.where(content_key: content_key).maximum(:occurrence).to_i + 1
    end

    def amount_is_not_zero
      errors.add(:amount, "must be other than 0") if amount&.zero? && !errors.include?(:amount)
    end
end
