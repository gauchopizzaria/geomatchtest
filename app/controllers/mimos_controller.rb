# Endpoints JSON de Mimos (presentes virtuais) consumidos pelo app mobile.
# Conecta MimoPaymentService (Fase 2) aos clientes: catálogo de itens e envio.
class MimosController < ApplicationController
  include AuthenticatesForMobile

  # ApplicationController não registra authenticate_user! globalmente (cada
  # controller declara o seu) — nada a pular aqui, só o before_action próprio.
  skip_before_action :verify_authenticity_token, only: [ :create, :send_with_wallet ]
  before_action :authenticate_for_mobile!

  # GET /mimo_items/catalog
  def catalog
    items = MimoItem.active.ordered

    render json: {
      items: items.map { |item| catalog_item_json(item) }
    }
  end

  # POST /mimo/send
  # Params: mimo_item_id (obrigatório) + exatamente um de: receiver_id | phone
  #         message (opcional)
  def create
    mimo_item = MimoItem.active.find(params.require(:mimo_item_id))

    payment = MimoPaymentService.call(
      sender:         mobile_current_user,
      receiver:       receiver_user,
      receiver_phone: params[:phone].presence,
      mimo_item:      mimo_item,
      message:        params[:message]
    )

    mimo_transaction = payment.mimo_transaction
    render json: {
      payment_id: payment.id,
      mimo_transaction_id: mimo_transaction.id,
      checkout_url: payment.mercado_pago_checkout_url,
      status: mimo_transaction.status
    }, status: :created
  rescue ActionController::ParameterMissing => e
    render json: { error: e.message }, status: :bad_request
  rescue ActiveRecord::RecordNotFound => e
    render json: { error: e.message }, status: :not_found
  rescue MimoPaymentService::InvalidRecipientError, MimoPaymentService::ItemUnavailableError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue MimoPaymentService::ConfigurationError, MimoPaymentService::ProviderError => e
    Rails.logger.error "[MimosController] Falha de integração MP: #{e.class}: #{e.message}"
    render json: { error: "Não foi possível iniciar o pagamento no momento." }, status: :bad_request
  end

  # POST /mimo/send_with_wallet
  # Params: mimo_item_id + receiver_id (obrigatórios) — sem convite por telefone
  #         aqui (não há saldo a creditar em quem ainda não tem carteira).
  #         message (opcional). Transferência interna síncrona, sem Mercado Pago.
  def send_with_wallet
    mimo_item = MimoItem.active.find(params.require(:mimo_item_id))
    receiver  = receiver_user
    raise ActionController::ParameterMissing, :receiver_id if receiver.nil?

    mimo_transaction = MimoWalletPaymentService.call(
      sender: mobile_current_user,
      receiver: receiver,
      mimo_item: mimo_item,
      message: params[:message]
    )

    render json: {
      mimo_transaction_id: mimo_transaction.id,
      status: mimo_transaction.status
    }, status: :created
  rescue ActionController::ParameterMissing => e
    render json: { error: e.message }, status: :bad_request
  rescue ActiveRecord::RecordNotFound => e
    render json: { error: e.message }, status: :not_found
  rescue MimoWalletPaymentService::InsufficientBalanceError,
         MimoWalletPaymentService::InvalidRecipientError,
         MimoWalletPaymentService::ItemUnavailableError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def receiver_user
    return nil if params[:receiver_id].blank?

    User.find(params[:receiver_id])
  end

  def catalog_item_json(item)
    {
      id: item.id,
      name: item.name,
      description: item.description,
      icon: item.icon,
      price_cents: item.price_cents,
      price_formatted: item.price.format,
      position: item.position
    }
  end
end
