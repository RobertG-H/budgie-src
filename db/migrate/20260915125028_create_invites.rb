class CreateInvites < ActiveRecord::Migration[8.1]
  def change
    create_table :invites do |t|
      t.string :email, null: false
      t.datetime :accepted_at
      t.datetime :revoked_at
      t.references :user, foreign_key: true

      t.timestamps
    end
    add_index :invites, :email, unique: true
  end
end
