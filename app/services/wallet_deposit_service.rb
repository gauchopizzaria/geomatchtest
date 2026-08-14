# Orquestra o depósito de saldo na própria UserWallet via Mercado Pago (Checkout Pro):
#
#   .call      — cria o Payment (payment_type: wallet_deposit) e a preferência de
#                checkout no MP. Chamado pelo WalletsController quando o usuário
#                escolhe um valor na tela de depósito (app/views/pages/mimo_deposit.html.erb).
#   .complete! — chamado pelo MercadoPago::WebhookService quando o Payment associado
#                é aprovado: credita balance_cents da carteira do próprio usuário.
#   .sync!     — rede de segurança: consulta o MP e credita o depósito se lá ele já
#                estiver aprovado. Usada quando a notificação de webhook se perde
#                (ReconcilePendingDepositsJob e WalletsController#reconcile).
#   .revert!   — estorna o crédito quando o MP devolve/estorna o pagamento.
#
# Espelha a estrutura de MimoPaymentService, mas sem destinatário — o remetente
# e o beneficiário do crédito são a mesma pessoa.
class WalletDepositService
  require "mercadopago"

  class ConfigurationError < StandardError; end
  class ProviderError      < StandardError; end
  class CreditError        < StandardError; end

  MINIMUM_DEPOSIT_CENTS = 500 # R$ 5,00

  # Uma cobrança PIX precisa de folga: o usuário costuma sair do checkout, abrir o
  # banco e voltar. Uma hora (o valor anterior) derrubava o QR Code antes do
  # pagamento compensar, produzindo justamente o cenário "o dinheiro caiu mas o
  # pagamento não foi conciliado".
  CHECKOUT_EXPIRATION = 24.hours

  # Status do MP em que o dinheiro já é do lojista.
  APPROVED_STATUSES = %w[approved].freeze
  PENDING_STATUSES  = %w[pending in_process in_mediation authorized].freeze
  FAILED_STATUSES   = %w[rejected cancelled].freeze
  REVERSED_STATUSES = %w[refunded charged_back].freeze

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

  # Idempotente em dois níveis: o retorno antecipado cobre o caso comum (webhook
  # duplicado) e a releitura sob `with_lock` cobre a corrida real (duas
  # notificações processadas ao mesmo tempo por workers diferentes) — sem ela,
  # ambas passariam pelo primeiro `return` e creditariam o valor duas vezes.
  #
  # NÃO engole exceções: um crédito que falha precisa marcar o WebhookEvent como
  # `failed` para aparecer no monitoramento e ser reprocessado. Silenciar aqui era
  # o que fazia um depósito sumir sem deixar rastro.
  def self.complete!(payment)
    raise CreditError, "payment #{payment.id} não é um wallet_deposit" unless payment.wallet_deposit?
    return payment if payment.paid_at.present?

    amount_cents = payment.deposit_amount_cents.to_i
    raise CreditError, "payment #{payment.id} sem deposit_amount_cents válido (#{payment.deposit_amount_cents.inspect})" unless amount_cents.positive?

    ActiveRecord::Base.transaction do
      wallet = payment.user.wallet || payment.user.create_wallet!

      # with_lock: SELECT ... FOR UPDATE na carteira. Serializa os créditos
      # concorrentes; a releitura do Payment lá dentro enxerga o paid_at já
      # commitado pelo processo que chegou primeiro.
      wallet.with_lock do
        payment.reload
        next if payment.paid_at.present?

        wallet.update!(balance_cents: wallet.balance_cents + amount_cents)
        payment.update!(paid_at: Time.current)
      end
    end

    Rails.logger.info "[WalletDepositService] Depósito creditado — payment=#{payment.id} user=#{payment.user_id} amount_cents=#{amount_cents}"
    payment
  end

  # Estorno: o MP devolveu o dinheiro, então o saldo interno precisa acompanhar.
  # Debita no máximo o saldo livre (a carteira valida `balance_cents >= 0` e não
  # pode comer o que já está reservado em saque) e, se o usuário já gastou parte
  # do valor, registra a diferença como WalletReconciliation para resolução manual.
  #
  # `paid_at` é o mesmo marcador que `complete!` usa para "este depósito está
  # creditado"; limpá-lo aqui deixa os dois métodos simétricos e idempotentes. O
  # rastro do estorno fica no `state` (refunded) e no mercado_pago_payload.
  def self.revert!(payment)
    raise CreditError, "payment #{payment.id} não é um wallet_deposit" unless payment.wallet_deposit?
    return payment if payment.paid_at.blank? # nunca foi creditado (ou já estornado)

    amount_cents = payment.deposit_amount_cents.to_i
    return payment unless amount_cents.positive?

    ActiveRecord::Base.transaction do
      wallet = payment.user.wallet || payment.user.create_wallet!

      wallet.with_lock do
        payment.reload
        next if payment.paid_at.blank?

        balance_before = wallet.balance_cents
        debitable      = [ [ wallet.available_balance_cents, amount_cents ].min, 0 ].max
        shortfall      = amount_cents - debitable

        wallet.update!(balance_cents: balance_before - debitable) if debitable.positive?

        if shortfall.positive?
          # As colunas do WalletReconciliation são "esperado x real"; aqui o que
          # importa é o estorno, não o saldo: expected = quanto precisava ser
          # debitado, actual = quanto coube debitar. discrepancy fica negativo
          # (= falta a investigar), que é a semântica documentada no model.
          WalletReconciliation.create!(
            user_wallet: wallet,
            expected_balance_cents: amount_cents,
            actual_balance_cents: debitable,
            notes: "Estorno do depósito #{payment.id}: precisava debitar #{amount_cents} centavos, " \
                   "só foi possível debitar #{debitable} (saldo anterior #{balance_before}, " \
                   "restante já gasto ou reservado em saque). Resolver manualmente."
          )
        end

        payment.update!(paid_at: nil)
      end
    end

    Rails.logger.warn "[WalletDepositService] Depósito estornado — payment=#{payment.id} user=#{payment.user_id} amount_cents=#{amount_cents}"
    payment
  end

  # Consulta o estado real do pagamento no Mercado Pago e aplica localmente.
  # É o antídoto para notificação perdida: enquanto o webhook é "push" e pode
  # falhar em silêncio, isto é "pull" e sempre converge para o que o MP diz.
  def self.sync!(payment)
    raise CreditError, "payment #{payment.id} não é um wallet_deposit" unless payment.wallet_deposit?
    return payment if payment.paid_at.present?

    mp_payment = remote_payment_for(payment)
    if mp_payment.blank?
      Rails.logger.info "[WalletDepositService] Nenhum pagamento no MP para payment=#{payment.id} — nada a conciliar."
      return payment
    end

    status = mp_payment["status"].to_s

    case status
    when *APPROVED_STATUSES
      payment.approve!(mp_payment) if payment.may_approve?
      complete!(payment)
    when *FAILED_STATUSES
      payment.reject!(mp_payment) if payment.may_reject?
    when *PENDING_STATUSES
      payment.pending!(mp_payment) if payment.may_pending?
    when *REVERSED_STATUSES
      payment.refund!(mp_payment) if payment.may_refund?
    end

    payment
  end

  # Três caminhos para achar o pagamento no MP, do mais direto ao mais robusto.
  # Nenhum depende do webhook — é isso que faz o saldo convergir mesmo quando a
  # notificação nunca chega (notification_url errada, deploy fora do ar, etc.).
  def self.remote_payment_for(payment)
    by_known_id(payment) || by_external_reference(payment) || by_merchant_order(payment)
  rescue => e
    Rails.logger.error "[WalletDepositService] Falha ao consultar o MP para payment=#{payment.id}: #{e.class}: #{e.message}"
    nil
  end
  private_class_method :remote_payment_for

  # 1) Já sabemos o id do pagamento (uma notificação anterior chegou).
  def self.by_known_id(payment)
    return nil if payment.mercado_pago_payment_id.blank?

    normalize(class_sdk.payment.get(payment.mercado_pago_payment_id)).presence
  end
  private_class_method :by_known_id

  # 2) Busca pelo external_reference que gravamos na preferência (UUID do Payment).
  def self.by_external_reference(payment)
    results = normalize(class_sdk.payment.search(filters: { external_reference: payment.id.to_s }))
    best_candidate(Array(results["results"]))
  end
  private_class_method :by_external_reference

  # 3) Rede final: o Checkout Pro cria uma merchant_order por preferência, e ela
  # lista os pagamentos. Cobre os casos em que o external_reference não é
  # propagado para o pagamento (acontece com alguns meios, PIX incluído).
  def self.by_merchant_order(payment)
    return nil if payment.mercado_pago_preference_id.blank?

    orders = normalize(class_sdk.merchant_order.search(filters: { preference_id: payment.mercado_pago_preference_id }))
    order  = Array(orders["elements"]).first
    return nil if order.blank?

    # A order traz os pagamentos resumidos; buscamos o completo para ter o payload inteiro.
    summary = best_candidate(Array(order["payments"]))
    return nil if summary.blank?

    normalize(class_sdk.payment.get(summary["id"])).presence || summary
  end
  private_class_method :by_merchant_order

  # Um mesmo checkout pode gerar várias tentativas — a aprovada é a que importa.
  def self.best_candidate(candidates)
    return nil if candidates.empty?

    candidates.find { |c| APPROVED_STATUSES.include?(c["status"].to_s) } ||
      candidates.max_by { |c| c["date_created"].to_s }
  end
  private_class_method :best_candidate

  def self.class_sdk
    token = ENV["MERCADO_PAGO_ACCESS_TOKEN"].presence ||
            raise(ConfigurationError, "MERCADO_PAGO_ACCESS_TOKEN não configurado")
    ::Mercadopago::SDK.new(token)
  end
  private_class_method :class_sdk

  def self.normalize(result)
    return {} if result.nil?
    return result["response"] if result.is_a?(Hash) && result.key?("response")
    return result[:response]  if result.is_a?(Hash) && result.key?(:response)
    result
  end
  private_class_method :normalize

  private

  attr_reader :user, :amount_cents, :payment

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
    log_notification_target!

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
      # binary_mode DESLIGADO de propósito: ele força o pagamento a terminar em
      # approved/rejected e é incompatível com meios assíncronos, que passam
      # legitimamente por "pending" — PIX é exatamente esse caso e é o meio
      # principal deste fluxo.
      binary_mode: false,
      statement_descriptor: "GEOMATCH",
      metadata: {
        payment_id: payment.id,
        user_id: user.id,
        deposit_amount_cents: amount_cents
      },
      expires: true,
      expiration_date_from: Time.current.iso8601,
      expiration_date_to: (Time.current + CHECKOUT_EXPIRATION).iso8601
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

  # Sem APP_BASE_URL o fallback é o host fixo de config/environments/production.rb.
  # Num ambiente com mais de um deploy (staging, preview do Render) isso aponta o
  # webhook para OUTRA instância e a notificação nunca chega neste app — falha
  # silenciosa que só aparece como "paguei o PIX e o saldo não subiu".
  def log_notification_target!
    if ENV["APP_BASE_URL"].blank?
      Rails.logger.warn "[WalletDepositService] APP_BASE_URL não configurado — usando fallback #{base_url.inspect}. " \
                        "Confirme que #{notification_url} aponta para ESTE deploy."
    else
      Rails.logger.info "[WalletDepositService] notification_url=#{notification_url}"
    end
  end

  def normalize_response(result)
    return {} if result.nil?
    return result["response"] if result.is_a?(Hash) && result.key?("response")
    return result[:response]  if result.is_a?(Hash) && result.key?(:response)
    result
  end
end
