class AddReadFromFloorToBudgetBankConnections < ActiveRecord::Migration[8.1]
  def change
    # Nothing is read from before 1990, as a CSV file's dates aren't (Budget::CsvFormat::Reader). The model says so too, and says the other limit, that it
    # can't be more than a day after today, which no constraint can since it depends on when it's asked.
    add_check_constraint :budget_bank_connections, "read_from >= DATE '1990-01-01'", name: "budget_bank_connections_read_from_not_before_1990"
  end
end
