# Orquestra o ciclo de vida de um Mimo (presente virtual) pago via Mercado Pago:
#
#   .call      — cria o Payment + a MimoTransaction (pending) e a preferência de
#                checkout no MP. Chamado pelo controller quando o remetente confirma o envio.
#                Aceita `receiver:` (usuário já cadastrado) OU `receiver_phone:`
#                (convite para quem ainda não tem conta) — nunca os dois.
#   .complete! — chamado pelo MercadoPago::WebhookService quando o Payment associado
#                é aprovado: credita a carteira do destinatário (ou dispara o SMS de
#                convite, se for um Mimo para telefone) e transfere o valor
#                correspondente da Conta Operacional para a Conta Bolsão.
#
# O split de taxas (MP + plataforma) vem do MimoFeeCalculator, não do
# `receiver_value_cents` estático do MimoItem (que era só uma referência de
# catálogo na Fase 1) — a fórmula de taxas é a fonte da verdade para o ledger.
class MimoPaymentService
  require "mercadopago"

  class ConfigurationError    < StandardError; end
  class ProviderError         < StandardError; end
  class InvalidRecipientError < StandardError; end
  class ItemUnavailableError  < StandardError; end

  def self.call(sender:, mimo_item:, receiver: nil, receiver_phone: nil, message: nil)
    new(
      sender: sender,
      receiver: receiver,
      receiver_phone: receiver_phone,
      mimo_item: mimo_item,
      message: message
    ).call
  end

  def initialize(sender:, mimo_item:, receiver: nil, receiver_phone: nil, message: nil)
    @sender         = sender
    @receiver       = receiver
    @receiver_phone = receiver_phone.presence
    @mimo_item      = mimo_item
    @message        = message
  end

  def call
    validate_recipients!
    create_records!
    create_mp_preference!
    payment
  rescue => e
    Rails.logger.error "[MimoPaymentService] Falha ao criar checkout — sender=#{sender&.id} receiver=#{receiver&.id || receiver_phone} error=#{e.class}: #{e.message}"
    mimo_transaction.mark_failed! if mimo_transaction&.may_mark_failed?
    raise
  end

  # Chamado quando o Mercado Pago confirma o pagamento (via webhook). Para um
  # destinatário já cadastrado, credita a carteira dele. Para um convite por
  # telefone (guest_invite?), não há carteira ainda — dispara o SMS de convite
  # e deixa a MimoTransaction "completed" aguardando resgate (pending_claim).
  def self.complete!(mimo_transaction)
    return mimo_transaction unless mimo_transaction.may_complete?

    if mimo_transaction.guest_invite?
      mimo_transaction.complete!
      send_guest_invite(mimo_transaction)
    else
      ActiveRecord::Base.transaction do
        wallet = mimo_transaction.receiver.wallet || mimo_transaction.receiver.create_wallet!

        # with_lock: SELECT ... FOR UPDATE — impede que dois créditos concorrentes
        # (ex.: dois webhooks duplicados) leiam o mesmo saldo antigo e percam um update.
        wallet.with_lock do
          wallet.update!(
            balance_cents: wallet.balance_cents + mimo_transaction.receiver_value_cents,
            lifetime_earned_cents: wallet.lifetime_earned_cents + mimo_transaction.receiver_value_cents
          )
        end

        mimo_transaction.complete!
      end
    end

    move_value_to_pool_account(mimo_transaction)
    mimo_transaction
  rescue => e
    Rails.logger.error "[MimoPaymentService] Falha ao completar mimo_transaction=#{mimo_transaction.id}: #{e.class}: #{e.message}"
    mimo_transaction.mark_failed! if mimo_transaction.may_mark_failed?
    mimo_transaction
  end

  def self.send_guest_invite(mimo_transaction)
    base_url = ENV["APP_BASE_URL"].presence || Rails.application.routes.default_url_options[:host]
    invite_url = "#{base_url.to_s.delete_suffix('/')}/instalar?convite=#{mimo_transaction.invite_token}"

    MimoInviteService.call(phone: mimo_transaction.receiver_phone, sender: mimo_transaction.sender, invite_url: invite_url)
  end
  private_class_method :send_guest_invite

  # Movimentação de tesouraria (Operacional -> Bolsão). Não bloqueia o crédito ao
  # usuário: se o MP recusar ou as contas ainda não estiverem configuradas, o
  # saldo interno já foi creditado corretamente — só registramos o problema para
  # reconciliação manual (ver WalletReconciliation / BolsaoReconciliationJob).
  def self.move_value_to_pool_account(mimo_transaction)
    MpTransferService.call(
      amount_cents: mimo_transaction.receiver_value_cents,
      direction: :to_pool,
      external_reference: mimo_transaction.id,
      description: "Mimo ##{mimo_transaction.id} — #{mimo_transaction.mimo_item.name}"
    )
  rescue MpTransferService::ConfigurationError => e
    Rails.logger.warn "[MimoPaymentService] MpTransferService não configurado — #{e.message}"
  rescue MpTransferService::TransferError => e
    Rails.logger.error "[MimoPaymentService] Falha ao mover valor p/ conta Bolsão (mimo_transaction=#{mimo_transaction.id}): #{e.message}"
  end
  private_class_method :move_value_to_pool_account

  private

  attr_reader :sender, :receiver, :receiver_phone, :mimo_item, :message, :payment, :mimo_transaction

  def validate_recipients!
    if receiver.present? == receiver_phone.present?
      raise InvalidRecipientError, "informe um destinatário cadastrado ou um telefone de convite, nunca os dois"
    end

    raise InvalidRecipientError, "remetente e destinatário não podem ser o mesmo usuário" if receiver && sender.id == receiver.id
    raise ItemUnavailableError, "este Mimo não está disponível no momento" unless mimo_item.active?
  end

  def fee_breakdown
    @fee_breakdown ||= MimoFeeCalculator.call(mimo_item.price_cents)
  end

  # Payment + MimoTransaction nascem juntos, atomicamente — nunca existe um sem o outro.
  def create_records!
    ActiveRecord::Base.transaction do
      @payment = Payment.create!(user: sender, payment_type: "mimo_purchase")
      @mimo_transaction = MimoTransaction.create!(
        sender: sender,
        receiver: receiver,
        receiver_phone: receiver_phone,
        invite_token: (receiver_phone.present? ? SecureRandom.urlsafe_base64(16) : nil),
        mimo_item: mimo_item,
        payment: payment,
        message: message,
        price_cents: fee_breakdown.gross_cents,
        mp_fee_cents: fee_breakdown.mp_fee_cents,
        platform_fee_cents: fee_breakdown.platform_fee_cents,
        receiver_value_cents: fee_breakdown.receiver_value_cents
      )
    end
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

  def recipient_description
    receiver.present? ? "Presente virtual para #{receiver.display_name}" : "Presente virtual — convite por SMS"
  end

  def build_preference_payload
    {
      items: [
        {
          id: "mimo_#{mimo_item.id}",
          title: "Mimo: #{mimo_item.name}",
          description: recipient_description,
          quantity: 1,
          currency_id: "BRL",
          unit_price: (fee_breakdown.gross_cents / 100.0).round(2)
        }
      ],
      payer: { email: sender.email, name: sender.username },
      external_reference: payment.id.to_s,
      notification_url: notification_url,
      back_urls: {
        success: "#{base_url}/meu-perfil?mimo=success",
        failure: "#{base_url}/meu-perfil?mimo=failure",
        pending: "#{base_url}/meu-perfil?mimo=pending"
      },
      auto_return: "approved",
      # Ver WalletDepositService: binary_mode force approved/rejected e é
      # incompatível com PIX, que passa legitimamente por "pending" até compensar.
      binary_mode: false,
      statement_descriptor: "GEOMATCH",
      metadata: {
        payment_id: payment.id,
        mimo_transaction_id: mimo_transaction.id,
        sender_id: sender.id,
        receiver_id: receiver&.id,
        receiver_phone: receiver_phone,
        mimo_item_id: mimo_item.id
      },
      expires: true,
      expiration_date_from: Time.current.iso8601,
      expiration_date_to: (Time.current + WalletDepositService::CHECKOUT_EXPIRATION).iso8601
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
