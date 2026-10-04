# A real bank or card account that bank transactions come from. Budgie doesn't track what's in it (ADR 0001): it has no
# balance, no currency (it uses its budget's), no kind and no last four digits. It's only where an Import reads a file into,
# and where deduplication looks for a row that's already there (ADR 0010).
class Budget::Account < ApplicationRecord
  belongs_to :budget
  # An Account with bank transactions can't be deleted: the model refuses with a reason, and the database's ON DELETE
  # RESTRICT is the backstop. Its Imports go with it, which only an Account without any of their bank transactions can
  # reach, so this stays after the check that refuses. Deleting the whole budget deletes them first (see Budget).
  has_many :bank_transactions, dependent: :restrict_with_error
  has_many :imports, dependent: :destroy

  normalizes :name, with: ->(name) { name.squish }

  validates :name, presence: true, uniqueness: { scope: :budget_id, case_sensitive: false }

  scope :alphabetical, -> { order(Arel.sql("lower(name)"), :id) }

  # The Import that ran last, which is the only one that can be undone, and the one whose CSV format the next Import
  # starts with. Imports made at the same moment go by the order they were made in.
  def latest_import
    imports.latest_first.first
  end
end
