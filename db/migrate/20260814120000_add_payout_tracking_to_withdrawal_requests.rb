# Rastreamento do envio automático do PIX (ver PixPayoutService).
#
# Sem estas colunas não há como garantir idempotência: uma nova tentativa do
# ProcessWithdrawalJob (retry_on, deploy no meio do job, admin clicando duas
# vezes) reenviaria o PIX e pagaria o usuário duas vezes. `payout_external_id`
# é a prova de que a ordem já foi criada no provedor.
class AddPayoutTrackingToWithdrawalRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :withdrawal_requests, :payout_provider,     :string
    add_column :withdrawal_requests, :payout_external_id,  :string
    add_column :withdrawal_requests, :payout_status,       :string
    add_column :withdrawal_requests, :payout_error,        :text
    add_column :withdrawal_requests, :payout_requested_at, :datetime
    add_column :withdrawal_requests, :payout_payload,      :jsonb

    # Único: dois registros nunca podem apontar para a mesma ordem de pagamento
    # no provedor. É a trava final contra pagamento duplicado.
    add_index :withdrawal_requests, [ :payout_provider, :payout_external_id ],
              unique: true,
              where: "payout_external_id IS NOT NULL",
              name: "index_withdrawal_requests_on_payout_identity"

    add_index :withdrawal_requests, :payout_status
  end
end
