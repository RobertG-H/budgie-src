class AddAssignmentsCopiedThroughToBudgets < ActiveRecord::Migration[8.1]
  def change
    # The latest month that new months have been started up to: Assigned has been copied into it from the month before.
    add_column :budgets, :assignments_copied_through, :date

    # A budget that already exists has begun this month without a copy, so its first copy is next month's.
    reversible do |direction|
      direction.up do
        execute "UPDATE budgets SET assignments_copied_through = #{connection.quote(Date.current.beginning_of_month)}"
      end
    end

    change_column_null :budgets, :assignments_copied_through, false
    add_check_constraint :budgets, "EXTRACT(DAY FROM assignments_copied_through) = 1", name: "budgets_assignments_copied_through_first_of_month"
  end
end
