# Diagnóstico do fluxo de depósito na carteira (Mimos).
#
#   bin/rails mimos:diagnose                      # últimos depósitos de todos
#   bin/rails mimos:diagnose[voce@email.com]      # só de um usuário
#   bin/rails mimos:reconcile                     # força a conciliação agora
#
# Responde às três perguntas que importam quando "o PIX caiu e o saldo não subiu":
#   1. Para onde o app manda o Mercado Pago notificar? (APP_BASE_URL)
#   2. Alguma notificação chegou? (webhook_events)
#   3. O que o Mercado Pago diz sobre esse pagamento? (consulta ao vivo)
namespace :mimos do
  desc "Diagnostica depósitos na carteira: config, webhooks recebidos e estado real no Mercado Pago"
  task :diagnose, [ :email ] => :environment do |_t, args|
    puts "\n=== CONFIGURAÇÃO ==="
    base_url = ENV["APP_BASE_URL"].presence || Rails.application.routes.default_url_options[:host]
    puts "APP_BASE_URL (env)........: #{ENV['APP_BASE_URL'].presence || '(não definido)'}"
    puts "Fallback (routes host)....: #{Rails.application.routes.default_url_options[:host].inspect}"
    puts "notification_url efetivo..: #{base_url.to_s.delete_suffix('/')}/webhooks/mercado_pago"
    puts "MERCADO_PAGO_ACCESS_TOKEN.: #{ENV['MERCADO_PAGO_ACCESS_TOKEN'].present? ? "definido (#{ENV['MERCADO_PAGO_ACCESS_TOKEN'][0, 8]}...)" : '(NÃO DEFINIDO)'}"
    puts "\n>> Se o notification_url acima não for a URL DESTE deploy, o Mercado Pago"
    puts ">> está notificando outro lugar e nenhum webhook chega aqui."

    puts "\n=== WEBHOOKS RECEBIDOS (últimos 10) ==="
    events = WebhookEvent.order(created_at: :desc).limit(10)
    if events.empty?
      puts "NENHUM webhook registrado. O Mercado Pago nunca conseguiu notificar este app."
    else
      events.each do |e|
        puts "#{e.created_at.strftime('%d/%m %H:%M')} topic=#{e.topic.inspect} external_id=#{e.external_id.inspect} status=#{e.status}"
        puts "    erro: #{e.processing_errors.to_s.lines.first&.strip}" if e.processing_errors.present?
      end
    end

    scope = Payment.wallet_deposit.order(created_at: :desc)
    if args[:email].present?
      user = User.find_by(email: args[:email])
      abort "Usuário #{args[:email]} não encontrado." if user.nil?
      scope = scope.where(user_id: user.id)
      puts "\n=== CARTEIRA DE #{user.email} ==="
      wallet = user.wallet
      puts wallet ? "saldo=#{Money.new(wallet.balance_cents, 'BRL').format}" : "carteira ainda não criada"
    end

    puts "\n=== DEPÓSITOS (últimos 10) ==="
    deposits = scope.limit(10).to_a
    puts "Nenhum depósito encontrado." if deposits.empty?

    deposits.each do |payment|
      valor = Money.new(payment.deposit_amount_cents.to_i, "BRL").format
      puts "\n#{payment.created_at.strftime('%d/%m %H:%M')} | #{valor} | id=#{payment.id}"
      puts "  local ....: state=#{payment.state} paid_at=#{payment.paid_at || '(não creditado)'}"
      puts "  mp .......: payment_id=#{payment.mercado_pago_payment_id.inspect} preference_id=#{payment.mercado_pago_preference_id.inspect}"

      remote = fetch_remote_status(payment)
      puts "  Mercado Pago diz: #{remote}"
    end

    puts "\nPara creditar o que estiver aprovado: bin/rails mimos:reconcile\n\n"
  end

  desc "Consulta o Mercado Pago e credita os depósitos já aprovados que não foram creditados"
  task reconcile: :environment do
    pendentes = ReconcilePendingDepositsJob.pending_scope(30.days).count
    puts "Depósitos pendentes de conciliação: #{pendentes}"

    ReconcilePendingDepositsJob.new.perform(lookback: 30.days)

    puts "Concluído. Saldos após a conciliação:"
    UserWallet.where("balance_cents > 0").includes(:user).find_each do |w|
      puts "  #{w.user.email}: #{Money.new(w.balance_cents, 'BRL').format}"
    end
  end

  # Consulta ao vivo, tolerante a falha — o diagnóstico nunca deve explodir.
  def fetch_remote_status(payment)
    require "mercadopago"
    token = ENV["MERCADO_PAGO_ACCESS_TOKEN"].presence
    return "(sem MERCADO_PAGO_ACCESS_TOKEN, não dá para consultar)" if token.blank?

    sdk = Mercadopago::SDK.new(token)
    result = sdk.payment.search(filters: { external_reference: payment.id.to_s })
    body = result.is_a?(Hash) ? (result["response"] || result[:response] || result) : {}
    results = Array(body["results"])

    if results.empty?
      "nenhum pagamento com external_reference=#{payment.id} (o usuário pode não ter concluído o PIX)"
    else
      results.map { |r| "id=#{r['id']} status=#{r['status']} valor=#{r['transaction_amount']}" }.join(" | ")
    end
  rescue StandardError => e
    "erro ao consultar: #{e.class}: #{e.message}"
  end
end
