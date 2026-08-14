class CreateMimoTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :mimo_transactions, id: :uuid do |t|
      # sender/receiver referenciam :users — precisa apontar to_table explicitamente,
      # senão o Rails tentaria inferir as tabelas inexistentes "senders"/"receivers"
      t.references :sender,   null: false, foreign_key: { to_table: :users }
      t.references :receiver, null: false, foreign_key: { to_table: :users }
      t.references :mimo_item, null: false, foreign_key: true

      # Snapshot dos valores no momento do envio — o preço do MimoItem pode mudar
      # depois; o ledger tem que preservar o que realmente foi cobrado/creditado.
      t.integer :price_cents, null: false
      t.string  :price_currency, null: false, default: "BRL"
      t.integer :receiver_value_cents, null: false
      t.string  :receiver_value_currency, null: false, default: "BRL"

      t.text   :message
      t.string :status, null: false, default: "pending"

      t.timestamps
    end

    add_index :mimo_transactions, :status
    add_index :mimo_transactions, [ :sender_id, :receiver_id ]
    add_index :mimo_transactions, :created_at
  end
end
