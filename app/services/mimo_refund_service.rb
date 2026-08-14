# Estorna uma MimoTransaction já completada: devolve o dinheiro ao remetente via
# Mercado Pago e reverte o crédito que havia sido dado na carteira do destinatário.
#
# A chamada externa (MP) acontece ANTES de qualquer mudança no ledger interno —
# nunca mexemos no saldo do usuário sem confirmação de que o estorno no MP
# realmente aconteceu (efeito externo difícil de reverter vem primeiro).
#
# Se o destinatário já sacou/gastou parte do valor, a reversão não pode deixar
# o saldo negativo (violaria a validação do UserWallet) — o que não puder ser
# recuperado vira um registro em WalletReconciliation para revisão manual.
class MimoRefundService
  require "mercadopago"

  class ConfigurationError < StandardError; end
  class ProviderError      < StandardError; end
  class InvalidStateError  < StandardError; end

  def self.call(mimo_transaction:, reason: nil)
    new(mimo_transaction: mimo_transaction, reason: reason).call
  end

  def initialize(mimo_transaction:, reason: nil)
    @mimo_transaction = mimo_transaction
    @reason           = reason
  end

  def call
    raise InvalidStateError, "só é possível estornar um Mimo com status completed" unless mimo_transaction.may_refund?

    refund_at_mercado_pago!
    reverse_wallet_credit!
    mimo_transaction.refund!
    mimo_transaction
  rescue ConfigurationError, ProviderError => e
    Rails.logger.error "[MimoRefundService] Falha ao estornar mimo_transaction=#{mimo_transaction.id}: #{e.class}: #{e.message}"
    raise
  end

  private

  attr_reader :mimo_transaction, :reason

  def payment
    mimo_transaction.payment
  end

  def access_token
    ENV["MERCADO_PAGO_ACCESS_TOKEN"].presence ||
      raise(ConfigurationError, "MERCADO_PAGO_ACCESS_TOKEN não configurado")
  end

  def sdk
    @sdk ||= ::Mercadopago::SDK.new(access_token)
  end

  def refund_at_mercado_pago!
    mp_payment_id = payment&.mercado_pago_payment_id
    unless mp_payment_id.present?
      Rails.logger.warn "[MimoRefundService] mimo_transaction=#{mimo_transaction.id} sem mercado_pago_payment_id — pulando estorno externo"
      return
    end

    # refund_data: nil => estorno total (a gem só aceita refund_data como keyword;
    # passar um Hash posicional aqui levantaria ArgumentError).
    result = sdk.refund.create(mp_payment_id)
    response = normalize_response(result)

    raise ProviderError, "Mercado Pago não confirmou o estorno" if response.blank?
  rescue ConfigurationError, ProviderError
    raise
  rescue => e
    raise ProviderError, "Falha ao chamar o estorno no Mercado Pago: #{e.message}"
  end

  # Debita da carteira o que for possível (nunca deixa o saldo negativo); o que
  # não puder ser recuperado (já sacado/gasto) vira um WalletReconciliation.
  def reverse_wallet_credit!
    wallet = mimo_transaction.receiver.wallet
    return unless wallet

    ActiveRecord::Base.transaction do
      wallet.with_lock do
        original_balance = wallet.balance_cents
        reversible        = [ mimo_transaction.receiver_value_cents, original_balance ].min
        shortfall         = mimo_transaction.receiver_value_cents - reversible
        new_balance       = original_balance - reversible

        wallet.update!(balance_cents: new_balance)

        next unless shortfall.positive?

        WalletReconciliation.create!(
          user_wallet: wallet,
          actual_balance_cents: new_balance,
          expected_balance_cents: new_balance + shortfall,
          notes: "Estorno da MimoTransaction ##{mimo_transaction.id} (#{reason.presence || 'sem motivo informado'}): " \
                 "faltaram R$ #{'%.2f' % (shortfall / 100.0)} para reversão total — destinatário provavelmente já " \
                 "sacou ou gastou parte do valor."
        )
      end
    end
  end

  def normalize_response(result)
    return {} if result.nil?
    return result["response"] if result.is_a?(Hash) && result.key?("response")
    return result[:response]  if result.is_a?(Hash) && result.key?(:response)
    result
  end
end
