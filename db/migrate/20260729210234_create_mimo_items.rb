class CreateMimoItems < ActiveRecord::Migration[8.1]
  def change
    create_table :mimo_items do |t|
      t.string  :name, null: false
      t.text    :description
      t.string  :icon

      # Preço cobrado do remetente
      t.integer :price_cents, null: false, default: 0
      t.string  :price_currency, null: false, default: "BRL"

      # Valor creditado na carteira do destinatário (margem da plataforma =
      # price_cents - receiver_value_cents)
      t.integer :receiver_value_cents, null: false, default: 0
      t.string  :receiver_value_currency, null: false, default: "BRL"

      t.boolean :active, null: false, default: true
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :mimo_items, :name, unique: true
    add_index :mimo_items, :active
    add_index :mimo_items, :position
  end
end
