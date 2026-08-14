# Envia um convite por SMS para um número de telefone que ainda não tem conta
# no GeoMatch — ex.: "Fulano quer te enviar um Mimo, baixe o app pra receber!".
#
# O projeto ainda não integra nenhum provedor de SMS (sem Twilio/Zenvia/etc. no
# Gemfile). Este serviço é propositalmente agnóstico de provedor: fala HTTP via
# Faraday com uma URL/API key configuráveis por ENV, seguindo o mesmo padrão
# defensivo do PushNotificationJob (ENV ausente => loga aviso e não-operação,
# em vez de derrubar o fluxo que chamou este serviço).
#
# Escopo: apenas envia o SMS de convite. Criar uma MimoTransaction "pendente de
# resgate" para um número de telefone (sem User) exigiria estender o schema de
# mimo_transactions (receiver_id nullable + campos de convidado) — fora do
# escopo desta fase, que pediu especificamente o envio do SMS.
class MimoInviteService
  class ConfigurationError < StandardError; end
  class ProviderError      < StandardError; end

  def self.call(phone:, sender:, invite_url: nil)
    new(phone: phone, sender: sender, invite_url: invite_url).call
  end

  def initialize(phone:, sender:, invite_url: nil)
    @phone      = phone
    @sender     = sender
    @invite_url = invite_url
  end

  def call
    unless configured?
      Rails.logger.warn "[MimoInviteService] Provedor de SMS não configurado — skipping invite to #{masked_phone}"
      return false
    end

    send_sms!
    true
  rescue ProviderError => e
    Rails.logger.error "[MimoInviteService] Falha ao enviar SMS para #{masked_phone}: #{e.message}"
    false
  end

  private

  attr_reader :phone, :sender, :invite_url

  def configured?
    ENV["SMS_PROVIDER_URL"].present? && ENV["SMS_PROVIDER_API_KEY"].present?
  end

  def message_body
    "#{sender.display_name} quer te enviar um Mimo no GeoMatch! Baixe o app para receber: #{invite_url || default_invite_url}"
  end

  def default_invite_url
    base_url = ENV["APP_BASE_URL"].presence || Rails.application.routes.default_url_options[:host]
    "#{base_url.to_s.delete_suffix('/')}/instalar"
  end

  def masked_phone
    phone.to_s.gsub(/\d(?=\d{4})/, "*") # mantém só os últimos 4 dígitos visíveis nos logs
  end

  def send_sms!
    response = connection.post do |req|
      req.body = { to: phone, message: message_body }
    end

    raise ProviderError, "provedor de SMS retornou #{response.status}" unless response.success?

    response.body
  rescue Faraday::Error => e
    raise ProviderError, "falha de rede: #{e.message}"
  end

  def connection
    Faraday.new(url: ENV.fetch("SMS_PROVIDER_URL")) do |f|
      f.request :json
      f.response :json, content_type: /\bjson$/
      f.headers["Authorization"] = "Bearer #{ENV.fetch('SMS_PROVIDER_API_KEY')}"
      f.options.open_timeout = 5
      f.options.timeout      = 10
      f.adapter Faraday.default_adapter
    end
  end
end
