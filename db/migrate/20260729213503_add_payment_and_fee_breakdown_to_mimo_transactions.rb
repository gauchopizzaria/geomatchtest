class AddPaymentAndFeeBreakdownToMimoTransactions < ActiveRecord::Migration[8.1]
  def change
    # payments.id é uuid — a FK precisa do mesmo tipo (type: :uuid).
    # null: true porque o Payment é criado no mesmo instante da MimoTransaction
    # (MimoPaymentService), mas mantemos opcional por segurança/flexibilidade.
    add_reference :mimo_transactions, :payment,
                   type: :uuid, null: true, foreign_key: true, index: { unique: true }

    # Snapshot do split de taxas calculado pelo MimoFeeCalculator no momento do
    # envio — permite auditar/reconciliar sem depender da fórmula de taxa atual.
    add_column :mimo_transactions, :mp_fee_cents, :integer, null: false, default: 0
    add_column :mimo_transactions, :platform_fee_cents, :integer, null: false, default: 0
  end
end
