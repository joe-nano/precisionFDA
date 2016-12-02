class CreateLicenses < ActiveRecord::Migration
  def change
    create_table :licenses do |t|
      t.text :content
      t.references :user, index: true, foreign_key: true

      t.timestamps null: false
    end
  end
end
