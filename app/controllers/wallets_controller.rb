# Endpoints JSON da carteira do usuário, consumidos pelo app mobile.
# Conecta WithdrawalService (Fase 2) aos clientes: saldo, saque, chave PIX e extrato.
class WalletsController < ApplicationController
  include AuthenticatesForMobile

  # ApplicationController não registra authenticate_user! globalmente (cada
  # controller declara o seu) — nada a pular aqui, só o before_action próprio.
  skip_before_action :verify_authenticity_token, only: [ :withdraw, :update_pix_key, :deposit, :reconcile ]
  before_action :authenticate_for_mobile!
  before_action :set_wallet
  # Toda leitura da carteira concilia os depósitos pendentes ANTES de responder.
  # O webhook do Mercado Pago é otimização, não dependência: se a notificação não
  # chega (URL errada, deploy fora do ar, MP atrasado), o saldo ainda assim
  # aparece — quem abre a carteira recebe o estado real consultado no MP.
  before_action :reconcile_pending_deposits!, only: [ :show, :transactions, :reconcile ]
  before_action :disable_caching!, only: [ :show, :transactions, :reconcile ]

  # Teto por requisição: cada item vira pelo menos uma chamada HTTP ao Mercado
  # Pago e estes endpoints respondem de forma síncrona.
  MAX_RECONCILE_PER_REQUEST = 10

  # Evita martelar a API do MP quando o usuário fica atualizando a tela com um
  # PIX ainda não pago (o QR Code vive 24h). #reconcile ignora esta janela.
  RECONCILE_THROTTLE = 20.seconds

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
  # Conciliação forçada (ignora o throttle), usada no retorno do checkout e por
  # um botão de "atualizar" na tela. A conciliação em si roda no before_action.
  def reconcile
    render json: wallet_json.merge(reconciled: @reconciled_count.to_i)
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

  # Pergunta ao Mercado Pago o estado real de cada depósito ainda não creditado
  # e credita os aprovados. A consulta ao MP só acontece quando existe depósito
  # pendente (um `exists?` barato decide), então a carteira sem pendências
  # continua respondendo sem nenhuma chamada externa.
  def reconcile_pending_deposits!
    @reconciled_count = 0

    pending = ReconcilePendingDepositsJob.pending_scope
                                         .where(user_id: mobile_current_user.id)
                                         .limit(MAX_RECONCILE_PER_REQUEST)
                                         .to_a
    return if pending.empty?
    return if throttled?

    pending.each do |payment|
      WalletDepositService.sync!(payment)
      @reconciled_count += 1
    rescue StandardError => e
      # Falha de rede/credencial não pode impedir o usuário de ver o saldo.
      Rails.logger.error "[WalletsController] Falha ao conciliar payment=#{payment.id}: #{e.class}: #{e.message}"
    end

    @wallet.reload
  end

  # #reconcile é explícito (retorno do checkout, pull-to-refresh): sempre passa.
  # #show e #transactions são automáticos e podem ser chamados em rajada.
  def throttled?
    return false if action_name == "reconcile"

    key = "wallet_reconcile/#{mobile_current_user.id}"
    return true if Rails.cache.read(key)

    Rails.cache.write(key, true, expires_in: RECONCILE_THROTTLE)
    false
  rescue StandardError => e
    Rails.logger.warn "[WalletsController] Cache indisponível para o throttle de conciliação: #{e.class}: #{e.message}"
    false
  end

  # Saldo é dado vivo: um 304 servindo corpo antigo do cache do navegador faria o
  # usuário ver R$ 0,00 depois de o depósito já ter sido creditado.
  def disable_caching!
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    response.headers["Pragma"]        = "no-cache"
    response.headers["Expires"]       = "0"
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

  # Um saque solicitado NÃO é dinheiro que já saiu: ele fica reservado até um
  # admin aprovar e o PIX ser confirmado. Sem o status na tela o usuário lê
  # "- R$ 23,40" e conclui que o pagamento foi feito.
  WITHDRAWAL_STATUS_LABELS = {
    "pending"  => "Aguardando aprovação",
    "approved" => "Aprovado — em processamento",
    "paid"     => "Pago",
    "rejected" => "Recusado — valor devolvido ao saldo"
  }.freeze

  def withdrawal_entry(wr)
    {
      type: "withdrawal",
      id: wr.id,
      amount_cents: -wr.amount_cents,
      description: "Saque via PIX",
      status: wr.status,
      status_label: WITHDRAWAL_STATUS_LABELS[wr.status] || wr.status,
      # Só o saque pago moveu dinheiro de fato; os demais ainda são promessa.
      settled: wr.status == "paid",
      created_at: wr.created_at
    }
  end
end
