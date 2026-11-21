class AddFeaturesToUsers < ActiveRecord::Migration[8.1]
  # What the operator has turned on for a person, by name (User::FEATURES): for now only `plaid`, connecting a bank, since the Trial's Items are spent for good. Empty
  # for everyone to start with, and only names that are known, which the check constraint says too, so adding a feature adds its name there.
  def change
    add_column :users, :features, :string, array: true, null: false, default: []
    add_check_constraint :users, "features <@ ARRAY['plaid']::character varying[]", name: "users_features_known"
  end
end
