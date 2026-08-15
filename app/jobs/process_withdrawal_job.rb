# Executa, assincronamente, um saque já APROVADO por um admin
# (WithdrawalService.approve! enfileira este job). Duas etapas:
#
#   1. Tesouraria interna — MpTransferService move o valor da Conta Bolsão de
#      volta para a Conta Operacional, de onde o pagamento sai.
#   2. Envio do PIX — PixPayoutService manda o dinheiro para a chave do usuário.
#      Só depois de o provedor CONFIRMAR o envio é que mark_paid! debita o saldo.
#
# Sem provedor de payout configurado (PIX_PAYOUT_PROVIDER=manual, o padrão) a
# etapa 2 devolve :skipped e o comportamento é o histórico: o operador envia o
# PIX manualmente e dá baixa depois. O saque fica em `approved` até lá — nunca é
# marcado como pago sem alguém ter confirmado que o dinheiro saiu.
class ProcessWithdrawalJob < ApplicationJob
  queue_as :default

  retry_on MpTransferService::TransferError, wait: 30.seconds, attempts: 3

  def perform(withdrawal_request_id)
    withdrawal_request = WithdrawalRequest.find_by(id: withdrawal_request_id)
    return unless withdrawal_request
    return unless withdrawal_request.approved?

    move_to_operational_account!(withdrawal_request)
    settle!(withdrawal_request)
  rescue MpTransferService::TransferError => e
    Rails.logger.error "[ProcessWithdrawalJob] Falha na transferência (withdrawal_request=#{withdrawal_request_id}): #{e.message}"
    raise # deixa o retry_on tentar novamente antes de desistir
  rescue WithdrawalService::InvalidStateError => e
    Rails.logger.warn "[ProcessWithdrawalJob] Estado inválido para withdrawal_request=#{withdrawal_request_id}: #{e.message}"
  end

  private

  # Contas não configuradas não podem travar o saque: o ledger interno já está
  # correto e a movimentação entre contas próprias é conciliável depois
  # (WalletReconciliation / BolsaoReconciliationJob).
  def move_to_operational_account!(withdrawal_request)
    MpTransferService.call(
      amount_cents: withdrawal_request.amount_cents,
      direction: :to_operational,
      external_reference: withdrawal_request.id,
      description: "Saque ##{withdrawal_request.id} — #{withdrawal_request.user.display_name}"
    )
  rescue MpTransferService::ConfigurationError => e
    Rails.logger.warn "[ProcessWithdrawalJob] MpTransferService não configurado (withdrawal_request=#{withdrawal_request.id}) — #{e.message}"
  end

  def settle!(withdrawal_request)
    result = PixPayoutService.call(withdrawal_request)

    if result.succeeded?
      # Único caminho para o débito definitivo: provedor confirmou o envio.
      WithdrawalService.mark_paid!(withdrawal_request, admin: withdrawal_request.processed_by)
      Rails.logger.info "[ProcessWithdrawalJob] withdrawal_request=#{withdrawal_request.id} pago " \
                        "(payout=#{withdrawal_request.payout_external_id})"
    elsif result.pending?
      # Ordem aceita e ainda processando. O saldo continua reservado; a baixa
      # vem de CheckPendingPayoutsJob quando o provedor confirmar.
      Rails.logger.info "[ProcessWithdrawalJob] withdrawal_request=#{withdrawal_request.id} com payout em " \
                        "processamento (payout=#{withdrawal_request.payout_external_id}) — aguardando confirmação."
    elsif result.skipped?
      Rails.logger.info "[ProcessWithdrawalJob] withdrawal_request=#{withdrawal_request.id} aguarda envio MANUAL do PIX " \
                        "para #{withdrawal_request.pix_key} (#{withdrawal_request.amount.format})."
    else
      # Falhou: não dá baixa. O valor segue reservado e a solicitação continua
      # `approved`, pronta para nova tentativa depois de resolver a causa.
      Rails.logger.error "[ProcessWithdrawalJob] Payout falhou para withdrawal_request=#{withdrawal_request.id}: #{result.error}"
    end
  end
end
