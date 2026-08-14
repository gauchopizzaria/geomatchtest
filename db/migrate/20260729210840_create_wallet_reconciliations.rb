class CreateWalletReconciliations < ActiveRecord::Migration[8.1]
  def change
    create_table :wallet_reconciliations, id: :uuid do |t|
      # user_wallets usa PK uuid — a FK precisa do mesmo tipo (type: :uuid)
      t.references :user_wallet, type: :uuid, null: false, foreign_key: true

      # Admin que revisou a divergência — null até ser revisado
      t.references :reconciled_by, null: true, foreign_key: { to_table: :users }

      # expected: soma calculada a partir do ledger (mimo_transactions/withdrawals)
      # actual: valor que estava de fato gravado em user_wallets.balance_cents
      t.integer :expected_balance_cents, null: false
      t.integer :actual_balance_cents, null: false
      t.integer :discrepancy_cents, null: false, default: 0

      t.string :status, null: false, default: "pending"
      t.text     :notes
      t.datetime :reconciled_at

      t.timestamps
    end

    add_index :wallet_reconciliations, :status
    add_index :wallet_reconciliations, :discrepancy_cents
  end
end
