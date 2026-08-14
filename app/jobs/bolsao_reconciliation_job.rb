# Cruza diariamente o saldo REAL da Conta Bolsão no Mercado Pago com o que o
# ledger interno diz que deveria estar lá (soma de todas as user_wallets) —
# a Conta Bolsão existe justamente para lastrear 1:1 o saldo sacável dos
# usuários (ver MpTransferService).
#
# NOTA — endpoint de saldo: a gem mercadopago-sdk não expõe um recurso de saldo
# de conta (só preference/payment/refund/user/etc.), e o Mimos-doc desta fase
# não especificou o endpoint exato para consultar o saldo de uma sub-conta
# específica (Bolsão). Usamos /v1/account/balance, que é o endpoint mais
# comumente documentado para isso hoje — validar contra a documentação atual
# do Mercado Pago antes de confiar neste job em produção.
#
# Diferença encontrada não é persistida em WalletReconciliation (esse model é
# por user_wallet_id, não serve para uma divergência agregada/sistêmica) —
# fica registrada em log estruturado para o monitoramento (Sentry/log
# aggregator) alertar a equipe de operações.
class BolsaoReconciliationJob < ApplicationJob
  queue_as :default

  BALANCE_ENDPOINT = "/v1/account/balance"

  def perform
    expected_cents = UserWallet.sum(:balance_cents)
    actual_cents   = fetch_pool_account_balance_cents

    if actual_cents.nil?
      Rails.logger.warn "[BolsaoReconciliationJob] Não foi possível obter o saldo real da Conta Bolsão — pulando comparação."
      return
    end

    discrepancy_cents = actual_cents - expected_cents

    if discrepancy_cents.zero?
      Rails.logger.info "[BolsaoReconciliationJob] OK — bolsao_cents=#{actual_cents} soma_carteiras_cents=#{expected_cents}"
    else
      Rails.logger.error "[BolsaoReconciliationJob] DIVERGÊNCIA — bolsao_cents=#{actual_cents} " \
                          "soma_carteiras_cents=#{expected_cents} discrepancy_cents=#{discrepancy_cents}"
    end
  rescue MpTransferService::ConfigurationError => e
    Rails.logger.warn "[BolsaoReconciliationJob] Contas/credenciais MP não configuradas — #{e.message}"
  end

  private

  def access_token
    ENV["MERCADO_PAGO_ACCESS_TOKEN"].presence ||
      raise(MpTransferService::ConfigurationError, "MERCADO_PAGO_ACCESS_TOKEN não configurado")
  end

  def pool_account_id
    ENV["MERCADO_PAGO_POOL_ACCOUNT_ID"].presence ||
      raise(MpTransferService::ConfigurationError, "MERCADO_PAGO_POOL_ACCOUNT_ID não configurado")
  end

  def fetch_pool_account_balance_cents
    response = connection.get(BALANCE_ENDPOINT, { user_id: pool_account_id })

    unless response.success?
      Rails.logger.error "[BolsaoReconciliationJob] Mercado Pago retornou #{response.status} em #{BALANCE_ENDPOINT}"
      return nil
    end

    amount = response.body.is_a?(Hash) ? (response.body["available_balance"] || response.body["total_amount"]) : nil
    amount.nil? ? nil : (amount.to_f * 100).round
  rescue Faraday::Error => e
    Rails.logger.error "[BolsaoReconciliationJob] Falha de rede ao consultar saldo: #{e.message}"
    nil
  end

  def connection
    Faraday.new(url: "https://api.mercadopago.com") do |f|
      f.response :json, content_type: /\bjson$/
      f.headers["Authorization"] = "Bearer #{access_token}"
      f.options.open_timeout = 5
      f.options.timeout      = 15
      f.adapter Faraday.default_adapter
    end
  end
end
