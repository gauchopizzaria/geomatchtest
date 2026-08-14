class CreateWithdrawalRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :withdrawal_requests, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true

      # Admin que processou o saque — null até ser aprovado/rejeitado/pago
      t.references :processed_by, null: true, foreign_key: { to_table: :users }

      t.integer :amount_cents, null: false
      t.string  :amount_currency, null: false, default: "BRL"

      t.string :status, null: false, default: "pending"

      # Destino do PIX informado pelo usuário no momento da solicitação
      t.string :pix_key
      t.string :pix_key_type

      t.text     :admin_notes
      t.datetime :processed_at

      t.timestamps
    end

    add_index :withdrawal_requests, :status
  end
end
