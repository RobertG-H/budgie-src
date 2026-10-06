# A real bank or card account that bank transactions come from. Budgie doesn't track what's in it (ADR 0001): it has no
# balance, no currency (it uses its budget's), no kind and no last four digits. It's only where an Import reads a file into,
# and where deduplication looks for a row that's already there (ADR 0010).
#
# It can remember which CSV format its bank's files use (`default_csv_format`), which an Import from the header uses to tell which Account
# a file is for, and which its own Import form starts on. It's optional, set by hand on the Account's form or by the first Import into it
# (Budget::Import#run), and an Import never changes one that's there.
#
# `files_with_rules` is on for every Account to start with, and means its bank transactions are filed or ignored by the Budget's Filing rules as they
# come in (ADR 0012). Turned off, no rule acts on them, so each waits unfiled for a person, while a Guess can still help. It's only ever read when a
# rule would act, which is when a bank transaction arrives and when a rule is saved: turning it on again files nothing that's already there, and turning it
# off leaves what rules already filed as it is.
class Budget::Account < ApplicationRecord
  belongs_to :budget
  belongs_to :default_csv_format, class_name: "Budget::CsvFormat", optional: true
  # An Account with bank transactions can't be deleted: the model refuses with a reason, and the database's ON DELETE
  # RESTRICT is the backstop. Its Imports go with it, which only an Account without any of their bank transactions can
  # reach, so this stays after the check that refuses. Deleting the whole budget deletes them first (see Budget).
  has_many :bank_transactions, dependent: :restrict_with_error
  has_many :imports, dependent: :destroy
  # The Filing rules pinned to it, which fit nothing once it's gone. Only an Account without bank transactions can be deleted, so
  # none of them is named by a bank transaction that a rule filed there.
  has_many :filing_rules, dependent: :destroy

  normalizes :name, with: ->(name) { name.squish }

  validates :name, presence: true, uniqueness: { scope: :budget_id, case_sensitive: false }
  validate :default_csv_format_is_in_this_budget

  scope :alphabetical, -> { order(Arel.sql("lower(name)"), :id) }
  # Whether Filing rules act on their bank transactions (`files_with_rules`, see the top). One that's off has every bank transaction wait for a person.
  scope :with_filing_rules, -> { where(files_with_rules: true) }
  scope :without_filing_rules, -> { where(files_with_rules: false) }

  # The Import that ran last, which is the only one that can be undone, and the one whose CSV format the next Import
  # starts with. Imports made at the same moment go by the order they were made in.
  def latest_import
    imports.latest_first.first
  end

  private
    # Which budget a CSV format is in is up to the model: no foreign key can say. A format that doesn't exist at all is refused the same way,
    # rather than left to the database's foreign key.
    def default_csv_format_is_in_this_budget
      return if default_csv_format_id.blank?

      errors.add(:default_csv_format, "isn't one of this budget's") unless default_csv_format&.budget_id == budget_id
    end
end
