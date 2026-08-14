# Endpoints JSON da carteira do usuário, consumidos pelo app mobile.
# Conecta WithdrawalService (Fase 2) aos clientes: saldo, saque, chave PIX e extrato.
class WalletsController < ApplicationController
  include AuthenticatesForMobile

  # ApplicationController não registra authenticate_user! globalmente (cada
  # controller declara o seu) — nada a pular aqui, só o before_action próprio.
  skip_before_action :verify_authenticity_token, only: [ :withdraw, :update_pix_key, :deposit, :reconcile ]
  before_action :authenticate_for_mobile!
  before_action :set_wallet

  # Teto por requisição em #reconcile: cada item vira pelo menos uma chamada HTTP
  # ao Mercado Pago e este endpoint responde de forma síncrona.
  MAX_RECONCILE_PER_REQUEST = 10

  # GET /wallet
  def show
    render json: wallet_json
  end

  # POST /wallet/withdraw
  # Params: amount_cents (obrigatório); pix_key/pix_key_type (opcionais — usa o
  # que estiver salvo na carteira se omitidos, ver #update_pix_key).
  def withdraw
    # ProcessWithdrawalJob só entra em cena quando um admin aprovar a solicitação
    # (ver WithdrawalService.approve!) — aqui ela nasce "pending", aguardando revisão.
    withdrawal_request = WithdrawalService.request!(
      user: mobile_current_user,
      amount_cents: params.require(:amount_cents).to_i,
      pix_key: params[:pix_key],
      pix_key_type: params[:pix_key_type]
    )

    render json: {
      withdrawal_request_id: withdrawal_request.id,
      amount_cents: withdrawal_request.amount_cents,
      status: withdrawal_request.status
    }, status: :created
  rescue ActionController::ParameterMissing => e
    render json: { error: e.message }, status: :bad_request
  rescue WithdrawalService::MinimumAmountError,
         WithdrawalService::RateLimitedError,
         WithdrawalService::InsufficientBalanceError,
         WithdrawalService::MissingPixKeyError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /wallet/deposit
  # Params: amount_cents (obrigatório) — devolve o link de checkout do Mercado
  # Pago; o crédito em si só acontece quando o webhook confirmar o pagamento
  # (ver WalletDepositService.complete! / MercadoPago::WebhookService).
  def deposit
    payment = WalletDepositService.call(
      user: mobile_current_user,
      amount_cents: params.require(:amount_cents).to_i
    )

    render json: {
      payment_id: payment.id,
      checkout_url: payment.mercado_pago_checkout_url
    }, status: :created
  rescue ActionController::ParameterMissing => e
    render json: { error: e.message }, status: :bad_request
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue WalletDepositService::ConfigurationError, WalletDepositService::ProviderError => e
    Rails.logger.error "[WalletsController] Falha de integração MP: #{e.class}: #{e.message}"
    render json: { error: "Não foi possível iniciar o depósito no momento." }, status: :bad_request
  end

  # POST /wallet/reconcile
  # Chamado pela tela da carteira quando o usuário volta do checkout do Mercado
  # Pago (/carteira?deposito=success|pending). Pergunta ao MP o estado real dos
  # depósitos ainda não creditados deste usuário e credita os já aprovados —
  # assim o saldo aparece na hora mesmo que a notificação de webhook se perca,
  # sem esperar o ReconcilePendingDepositsJob.
  def reconcile
    pending = ReconcilePendingDepositsJob.pending_scope
                                         .where(user_id: mobile_current_user.id)
                                         .limit(MAX_RECONCILE_PER_REQUEST)
                                         .to_a

    pending.each do |payment|
      WalletDepositService.sync!(payment)
    rescue StandardError => e
      Rails.logger.error "[WalletsController] Falha ao conciliar payment=#{payment.id}: #{e.class}: #{e.message}"
    end

    @wallet.reload
    render json: wallet_json.merge(reconciled: pending.size)
  end

  # PATCH /wallet/update_pix_key
  def update_pix_key
    pix_key_type = params.require(:pix_key_type)
    pix_key      = params.require(:pix_key)

    unless UserWallet::PIX_KEY_TYPES.include?(pix_key_type)
      return render json: { error: "pix_key_type inválido — use um de: #{UserWallet::PIX_KEY_TYPES.join(', ')}" },
                    status: :unprocessable_entity
    end

    @wallet.update!(pix_key: pix_key, pix_key_type: pix_key_type)
    render json: wallet_json
  rescue ActionController::ParameterMissing => e
    render json: { error: e.message }, status: :bad_request
  end

  # GET /wallet/transactions
  # Extrato combinado: Mimos recebidos + depósitos aprovados (créditos) e
  # solicitações de saque (débitos). Depósitos entram aqui porque sem eles o
  # saldo subia sem nenhuma linha correspondente no histórico — o usuário não
  # tinha como conferir se o PIX que pagou virou saldo.
  def transactions
    mimos_in    = mobile_current_user.mimo_transactions_received.completed.recent.limit(50).to_a
    withdrawals = mobile_current_user.withdrawal_requests.recent.limit(50).to_a
    deposits    = mobile_current_user.payments
                                     .wallet_deposit
                                     .where.not(paid_at: nil)
                                     .latest_first
                                     .limit(50)
                                     .to_a

    entries = (mimos_in.map { |mt| mimo_entry(mt) } +
               withdrawals.map { |wr| withdrawal_entry(wr) } +
               deposits.map { |p| deposit_entry(p) })
              .sort_by { |entry| entry[:created_at] }
              .reverse

    render json: { transactions: entries }
  end

  private

  def set_wallet
    @wallet = mobile_current_user.wallet || mobile_current_user.create_wallet!
  end

  def wallet_json
    {
      balance_cents: @wallet.balance_cents,
      balance_formatted: @wallet.balance.format,
      available_balance_cents: @wallet.available_balance_cents,
      pending_withdrawal_cents: @wallet.pending_withdrawal_cents,
      lifetime_earned_cents: @wallet.lifetime_earned_cents,
      lifetime_withdrawn_cents: @wallet.lifetime_withdrawn_cents,
      pix_key: @wallet.pix_key,
      pix_key_type: @wallet.pix_key_type
    }
  end

  def mimo_entry(mt)
    {
      type: "mimo_received",
      id: mt.id,
      amount_cents: mt.receiver_value_cents,
      description: "Mimo de #{mt.sender.display_name}: #{mt.mimo_item.name}",
      status: mt.status,
      created_at: mt.created_at
    }
  end

  def deposit_entry(payment)
    {
      type: "deposit",
      id: payment.id,
      amount_cents: payment.deposit_amount_cents.to_i,
      description: "Depósito via Mercado Pago",
      status: payment.state,
      created_at: payment.paid_at || payment.created_at
    }
  end

  def withdrawal_entry(wr)
    {
      type: "withdrawal",
      id: wr.id,
      amount_cents: -wr.amount_cents,
      description: "Saque via PIX",
      status: wr.status,
      created_at: wr.created_at
    }
  end
end
