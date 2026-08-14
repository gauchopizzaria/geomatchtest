class CreateUserWallets < ActiveRecord::Migration[8.1]
  def change
    create_table :user_wallets, id: :uuid do |t|
      # unique: 1 carteira por usuário
      t.references :user, null: false, foreign_key: true, index: { unique: true }

      # Saldo disponível para saque
      t.integer :balance_cents, null: false, default: 0
      t.string  :balance_currency, null: false, default: "BRL"

      # Bloqueado por withdrawal_requests em andamento (pending/approved) —
      # impede que o usuário solicite saque acima do que realmente tem livre
      t.integer :pending_withdrawal_cents, null: false, default: 0

      # Acumulados históricos (auditoria — nunca diminuem, exceto reconciliação manual)
      t.integer :lifetime_earned_cents, null: false, default: 0
      t.integer :lifetime_withdrawn_cents, null: false, default: 0

      t.timestamps
    end
  end
end
