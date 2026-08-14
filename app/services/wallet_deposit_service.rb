# Orquestra o depósito de saldo na própria UserWallet via Mercado Pago (Checkout Pro):
#
#   .call      — cria o Payment (payment_type: wallet_deposit) e a preferência de
#                checkout no MP. Chamado pelo WalletsController quando o usuário
#                escolhe um valor na tela de depósito (app/views/pages/mimo_deposit.html.erb).
#   .complete! — chamado pelo MercadoPago::WebhookService quando o Payment associado
#                é aprovado: credita balance_cents da carteira do próprio usuário.
#
# Espelha a estrutura de MimoPaymentService, mas sem destinatário — o remetente
# e o beneficiário do crédito são a mesma pessoa.
class WalletDepositService
  require "mercadopago"

  class ConfigurationError < StandardError; end
  class ProviderError      < StandardError; end

  def self.call(user:, amount_cents:)
    new(user: user, amount_cents: amount_cents).call
  end

  def initialize(user:, amount_cents:)
    @user         = user
    @amount_cents = amount_cents.to_i
  end

  def call
    validate_amount!
    create_payment!
    create_mp_preference!
    payment
  rescue => e
    Rails.logger.error "[WalletDepositService] Falha ao criar checkout de depósito — user=#{user&.id} error=#{e.class}: #{e.message}"
    raise
  end

  # Idempotente: se o Payment já foi processado (paid_at presente), uma segunda
  # notificação de webhook duplicada não credita o saldo de novo.
  def self.complete!(payment)
    return payment if payment.paid_at.present?

    ActiveRecord::Base.transaction do
      wallet = payment.user.wallet || payment.user.create_wallet!

      # with_lock: SELECT ... FOR UPDATE — mesma técnica de MimoPaymentService.complete!,
      # evita que um crédito concorrente (webhook duplicado) leia o saldo antigo.
      wallet.with_lock do
        wallet.update!(balance_cents: wallet.balance_cents + payment.deposit_amount_cents)
      end

      payment.update!(paid_at: Time.current)
    end

    payment
  rescue => e
    Rails.logger.error "[WalletDepositService] Falha ao creditar depósito payment=#{payment.id}: #{e.class}: #{e.message}"
    payment
  end

  private

  attr_reader :user, :amount_cents, :payment

  MINIMUM_DEPOSIT_CENTS = 500 # R$ 5,00

  def validate_amount!
    raise ArgumentError, "valor mínimo de depósito é #{Money.new(MINIMUM_DEPOSIT_CENTS, "BRL").format}" if amount_cents < MINIMUM_DEPOSIT_CENTS
  end

  def create_payment!
    @payment = Payment.create!(
      user: user,
      payment_type: "wallet_deposit",
      deposit_amount_cents: amount_cents
    )
  end

  def access_token
    ENV["MERCADO_PAGO_ACCESS_TOKEN"].presence ||
      raise(ConfigurationError, "MERCADO_PAGO_ACCESS_TOKEN não configurado")
  end

  def sdk
    @sdk ||= ::Mercadopago::SDK.new(access_token)
  end

  def create_mp_preference!
    result   = sdk.preference.create(build_preference_payload)
    response = normalize_response(result)

    checkout_url  = response["init_point"]&.to_s
    preference_id = response["id"]&.to_s
    raise ProviderError, "Mercado Pago não retornou init_point" if checkout_url.blank?

    payment.update!(
      mercado_pago_preference_id: preference_id,
      mercado_pago_checkout_url: checkout_url,
      mercado_pago_payload: response
    )
  end

  def build_preference_payload
    {
      items: [
        {
          id: "wallet_deposit",
          title: "Depósito na carteira GeoMatch",
          description: "Adicionar saldo à carteira digital",
          quantity: 1,
          currency_id: "BRL",
          unit_price: (amount_cents / 100.0).round(2)
        }
      ],
      payer: { email: user.email, name: user.username },
      external_reference: payment.id.to_s,
      notification_url: notification_url,
      back_urls: {
        success: "#{base_url}/carteira?deposito=success",
        failure: "#{base_url}/carteira?deposito=failure",
        pending: "#{base_url}/carteira?deposito=pending"
      },
      auto_return: "approved",
      binary_mode: true,
      statement_descriptor: "GEOMATCH",
      metadata: {
        payment_id: payment.id,
        user_id: user.id,
        deposit_amount_cents: amount_cents
      },
      expires: true,
      expiration_date_from: Time.current.iso8601,
      expiration_date_to: (Time.current + 1.hour).iso8601
    }
  end

  def base_url
    ENV["APP_BASE_URL"].presence ||
      Rails.application.routes.default_url_options[:host].presence ||
      raise(ConfigurationError, "APP_BASE_URL não configurado")
  end

  def notification_url
    "#{base_url.to_s.delete_suffix('/')}/webhooks/mercado_pago"
  end

  def normalize_response(result)
    return {} if result.nil?
    return result["response"] if result.is_a?(Hash) && result.key?("response")
    return result[:response]  if result.is_a?(Hash) && result.key?(:response)
    result
  end
end
