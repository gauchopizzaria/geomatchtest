# Fecha o ciclo dos saques cujo PIX foi aceito pelo provedor mas ainda não
# confirmado (PixPayoutService::Result :pending).
#
# Mesma lógica de ReconcilePendingDepositsJob, do outro lado do fluxo: em vez de
# esperar um aviso do provedor (push, que pode não chegar), o sistema pergunta
# (pull) e converge. Sem isto um saque aceito e depois confirmado ficaria
# eternamente `approved`, com o valor reservado e o usuário sem entender por quê.
#
# Agendado em config/schedule.yml (a cada 10 minutos).
class CheckPendingPayoutsJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 100

  def perform(limit: BATCH_SIZE)
    requests = self.class.pending_scope.limit(limit).to_a
    return if requests.empty?

    settled = 0

    requests.each do |withdrawal_request|
      result = PixPayoutService.call(withdrawal_request)

      if result.succeeded?
        WithdrawalService.mark_paid!(withdrawal_request, admin: withdrawal_request.processed_by)
        settled += 1
      elsif result.failed?
        Rails.logger.error "[CheckPendingPayoutsJob] Payout falhou para #{withdrawal_request.id}: #{result.error}"
      end
    rescue StandardError => e
      # Um saque problemático não pode impedir a checagem dos outros.
      Rails.logger.error "[CheckPendingPayoutsJob] Erro ao checar #{withdrawal_request.id}: #{e.class}: #{e.message}"
    end

    Rails.logger.info "[CheckPendingPayoutsJob] Verificados=#{requests.size} confirmados=#{settled}"
  end

  # Saques aprovados com uma ordem de payout já criada no provedor e ainda não
  # confirmada. `payout_external_id` presente garante que PixPayoutService vai
  # CONSULTAR o status, nunca reenviar o PIX.
  def self.pending_scope
    WithdrawalRequest.where(status: "approved")
                     .where.not(payout_external_id: nil)
                     .where(payout_status: %w[pending requested])
                     .order(payout_requested_at: :asc)
  end
end
