# Rede de segurança do depósito na carteira.
#
# O crédito normal depende de uma notificação do Mercado Pago (push). Notificação
# se perde: o MP pode não entregar, o app pode estar reiniciando no momento do
# POST, a URL pode ter mudado. Quando isso acontece, o dinheiro cai na conta do
# lojista e o saldo do usuário fica parado — sem nada no sistema que perceba.
#
# Este job faz o caminho inverso (pull): varre os depósitos que ainda não foram
# creditados e pergunta ao MP qual é o estado real de cada um, creditando os que
# já estão aprovados. É idempotente — WalletDepositService.complete! nunca credita
# duas vezes o mesmo Payment.
#
# Agendado em config/schedule.yml (a cada 15 minutos).
class ReconcilePendingDepositsJob < ApplicationJob
  queue_as :default

  # Janela de varredura. A preferência de checkout expira em 24h
  # (WalletDepositService::CHECKOUT_EXPIRATION); 7 dias dá folga para pagamentos
  # em análise e para uma indisponibilidade prolongada do webhook.
  LOOKBACK = 7.days

  # Teto por execução para não estourar o rate limit da API do MP num backlog.
  BATCH_SIZE = 200

  def perform(lookback: LOOKBACK, limit: BATCH_SIZE)
    payments = pending_deposits(lookback).limit(limit).to_a
    return if payments.empty?

    credited = 0

    payments.each do |payment|
      before = payment.paid_at
      WalletDepositService.sync!(payment)
      credited += 1 if before.blank? && payment.reload.paid_at.present?
    rescue StandardError => e
      # Um depósito problemático não pode impedir a conciliação dos outros.
      Rails.logger.error "[ReconcilePendingDepositsJob] Falha ao conciliar payment=#{payment.id}: #{e.class}: #{e.message}"
    end

    Rails.logger.info "[ReconcilePendingDepositsJob] Verificados=#{payments.size} creditados=#{credited}"
  end

  # Depósitos que o MP pode já ter aprovado sem que o app soubesse: sem paid_at
  # (não creditados) e ainda num estado não-terminal.
  def self.pending_scope(lookback = LOOKBACK)
    Payment.wallet_deposit
           .where(paid_at: nil, state: %w[created pending])
           .where(created_at: lookback.ago..)
           .order(created_at: :asc)
  end

  private

  def pending_deposits(lookback)
    self.class.pending_scope(lookback)
  end
end
