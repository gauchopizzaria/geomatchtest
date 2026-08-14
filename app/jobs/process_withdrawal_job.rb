# Executa, assincronamente, a movimentação financeira de uma solicitação de
# saque já APROVADA por um admin (ver WithdrawalService.approve!, que enfileira
# este job): move o valor da Conta Bolsão de volta para a Conta Operacional via
# MpTransferService e então marca a solicitação como paga (mark_paid!).
#
# IMPORTANTE — limite conhecido: a perna final "enviar o PIX para a chave do
# usuário" depende de um endpoint de payout do Mercado Pago que não foi
# especificado nesta fase (só recebemos a documentação do /v1/transfers para
# movimentação ENTRE contas da própria plataforma). Este job cobre a
# movimentação de tesouraria interna e a baixa no ledger; quando o endpoint
# real de payout PIX for definido, a chamada equivalente entra aqui, antes do
# mark_paid! — hoje o mark_paid! assume que o time de operações envia o PIX
# manualmente a partir da Conta Operacional após este job rodar.
class ProcessWithdrawalJob < ApplicationJob
  queue_as :default

  retry_on MpTransferService::TransferError, wait: 30.seconds, attempts: 3

  def perform(withdrawal_request_id)
    withdrawal_request = WithdrawalRequest.find_by(id: withdrawal_request_id)
    return unless withdrawal_request
    return unless withdrawal_request.approved?

    MpTransferService.call(
      amount_cents: withdrawal_request.amount_cents,
      direction: :to_operational,
      external_reference: withdrawal_request.id,
      description: "Saque ##{withdrawal_request.id} — #{withdrawal_request.user.display_name}"
    )

    WithdrawalService.mark_paid!(withdrawal_request, admin: withdrawal_request.processed_by)
    Rails.logger.info "[ProcessWithdrawalJob] withdrawal_request=#{withdrawal_request.id} processado com sucesso"
  rescue MpTransferService::ConfigurationError => e
    Rails.logger.warn "[ProcessWithdrawalJob] MpTransferService não configurado (withdrawal_request=#{withdrawal_request_id}) — #{e.message}"
  rescue MpTransferService::TransferError => e
    Rails.logger.error "[ProcessWithdrawalJob] Falha na transferência (withdrawal_request=#{withdrawal_request_id}): #{e.message}"
    raise # deixa o retry_on tentar novamente antes de desistir
  rescue WithdrawalService::InvalidStateError => e
    Rails.logger.warn "[ProcessWithdrawalJob] Estado inválido para withdrawal_request=#{withdrawal_request_id}: #{e.message}"
  end
end
