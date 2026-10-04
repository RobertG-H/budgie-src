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
#
# It's unfiled, filed or ignored, which is derived and never stored: ignored if `ignored_at` is set, filed if it has at least one
# link, and otherwise unfiled. It's never both ignored and filed, and never partly filed: Filing (Budget::Filing) makes every
# record and link at once, and they add up to its amount, though a record edited afterwards may stop it (the flag, see
# `adds_up?`, which blocks nothing, ADR 0009). It changes only through ignoring and un-ignoring, filing and un-filing, Undo, a
# sync's update, and deletion through its Account or Budget.
class Budget::BankTransaction < ApplicationRecord
  # Raised when a bank transaction can't be ignored, un-ignored or un-filed as asked; the message says why, for the person who
  # asked.
  class Refused < StandardError; end

  belongs_to :account
  belongs_to :import
  # What it was filed as, a link for each record. A bank transaction with links can't be deleted: the model refuses, and the
  # database's ON DELETE RESTRICT is the backstop. Un-filing, Undo and deleting the Budget delete the links with their records.
  has_many :deposit_links, class_name: "Budget::DepositLink", dependent: :restrict_with_error
  has_many :spend_links, class_name: "Budget::SpendLink", dependent: :restrict_with_error
  has_many :refund_links, class_name: "Budget::RefundLink", dependent: :restrict_with_error

  normalizes :description, with: ->(description) { description.strip }

  before_validation :set_content_key_and_occurrence, on: :create

  validates :description, presence: true
  validates :date, presence: true
  validates :amount, money: true
  validate :amount_is_not_zero
  validate :not_ignored_and_filed, if: :ignored_at_changed?

  scope :newest_first, -> { order(date: :desc, id: :desc) }
  # Neither ignored nor filed as anything. Left joins, so a bank transaction with several links is still found once.
  scope :unfiled, -> { where(ignored_at: nil).where.missing(:deposit_links, :spend_links, :refund_links) }

  # The records that were filed from the bank transactions in `transactions`, and their links, deleted straight from the tables
  # and without asking whether they add up. It's what un-filing, Undo and deleting the Budget all do, in the order that the
  # foreign keys allow: a link, then the record it holds.
  def self.delete_filed_records(transactions)
    ids = transactions.select(:id)

    { Budget::DepositLink => [ :deposit_id, Budget::Deposit ], Budget::SpendLink => [ :spend_id, Budget::Spend ],
      Budget::RefundLink => [ :refund_id, Budget::Refund ] }.each do |link_class, (column, record_class)|
      links = link_class.where(bank_transaction_id: ids)
      record_ids = links.pluck(column)
      links.delete_all
      record_class.where(id: record_ids).delete_all
    end
  end

  # The key of a row: a digest of its Account, date, signed amount and description, with the description trimmed, its
  # whitespace collapsed and its case folded, so a row that differs in nothing a person would notice is the same row.
  def self.content_key(account_id:, date:, amount:, description:)
    Digest::SHA256.hexdigest([ account_id, date.iso8601, format("%.2f", amount), normalize_description(description) ].join("\u001F"))
  end

  def self.normalize_description(description)
    description.squish.downcase(:fold)
  end

  def ignored?
    ignored_at.present?
  end

  def filed?
    [ deposit_links, spend_links, refund_links ].any?(&:any?)
  end

  def unfiled?
    !ignored? && !filed?
  end

  def state
    if ignored? then :ignored
    elsif filed? then :filed
    else :unfiled
    end
  end

  # The records it was filed as, which are ordinary Deposits, Spends and Refunds. Preload the links and their records for a list.
  def filed_records
    deposit_links.map(&:deposit) + spend_links.map(&:spend) + refund_links.map(&:refund)
  end

  # What its records add up to, which is every one's amount, since they're all positive.
  def filed_total
    filed_records.sum(&:amount)
  end

  # Whether its records add up to its amount, which they do when they're made. Editing one so they don't blocks nothing, and is
  # shown as a flag (ADR 0009). A bank transaction that isn't filed has nothing to add up, and isn't flagged.
  def adds_up?
    !filed? || filed_total == amount.abs
  end

  # Won't be filed: sets when it was ignored, such as for a card payment between a person's own accounts. Only an unfiled bank
  # transaction can be, which is judged once it's locked, so a record filed since it was looked at stops it.
  def ignore
    with_lock do
      raise Refused, "This bank transaction is filed. Un-file it before ignoring it." if filed?
      raise Refused, "This bank transaction is already ignored." if ignored?

      update!(ignored_at: Time.current)
    end
  end

  def unignore
    with_lock do
      raise Refused, "This bank transaction isn't ignored." unless ignored?

      update!(ignored_at: nil)
    end
  end

  # Deletes the records it was filed as and their links, which makes it unfiled again, in one transaction.
  def unfile
    with_lock do
      raise Refused, "This bank transaction isn't filed." unless filed?

      self.class.delete_filed_records(self.class.where(id: id))
    end
  end

  private
    # A row made one at a time is the next occurrence of its key. An Import numbers all of its rows itself, in one go.
    def set_content_key_and_occurrence
      return if content_key.present? || account_id.nil? || date.nil? || amount.nil? || description.blank?

      self.content_key = self.class.content_key(account_id: account_id, date: date, amount: amount, description: description)
      self.occurrence ||= account.bank_transactions.where(content_key: content_key).maximum(:occurrence).to_i + 1
    end

    def not_ignored_and_filed
      errors.add(:base, "Bank transaction is filed, so it can't be ignored") if ignored_at.present? && filed?
    end

    def amount_is_not_zero
      errors.add(:amount, "must be other than 0") if amount&.zero? && !errors.include?(:amount)
    end
end
