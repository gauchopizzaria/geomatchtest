module MercadoPago
  class WebhookService
    require "mercadopago"

    UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    def initialize(event)
      @event = event
      @sdk = ::Mercadopago::SDK.new(access_token)
    end

    def self.call(event:)
      new(event).call
    end

    def call
      return event if event.status == "processed"

      event.update!(status: "processing") if event.status != "processing"

      case normalized_topic
      when "payment"
        process_payment!
      when "merchant_order"
        # O Checkout Pro notifica merchant_order junto com payment. É a segunda
        # chance de conciliar quando a notificação de payment se perde.
        process_merchant_order!
      end

      event.update!(status: "processed", processed_at: Time.current)
    rescue StandardError => e
      event.update(
        status: "failed",
        processing_errors: "#{e.class}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
      )
    end

    private

    attr_reader :event, :sdk

    def access_token
      ENV["MERCADO_PAGO_ACCESS_TOKEN"].presence ||
        raise(StandardError, "MERCADO_PAGO_ACCESS_TOKEN não configurado")
    end

    def normalized_topic
      event.topic.to_s.presence ||
        event.payload["type"].to_s.presence ||
        event.payload["topic"].to_s.presence ||
        "unknown"
    end

    def process_payment!
      mp_payment_id = extract_mp_payment_id
      raise StandardError, "Mercado Pago payment id ausente no webhook" if mp_payment_id.blank?

      apply_mp_payment!(fetch_mp_payment(mp_payment_id))
    end

    def process_merchant_order!
      order_id = extract_mp_payment_id
      return if order_id.blank?

      order = normalize_response(sdk.merchant_order.get(order_id))
      Array(order["payments"]).each do |order_payment|
        payment_id = order_payment["id"].to_s
        next if payment_id.blank?

        apply_mp_payment!(fetch_mp_payment(payment_id))
      end
    end

    def apply_mp_payment!(mp_payment)
      payment = find_local_payment(mp_payment)

      if payment.nil?
        # Notificação de um pagamento que não nasceu neste app (ou de outra
        # aplicação na mesma conta MP). Não é erro — antes isso estourava
        # NoMethodError em `nil.one_off_message?` e marcava o evento como failed.
        Rails.logger.info "[MercadoPago::WebhookService] Payment local não encontrado — " \
                          "external_reference=#{mp_payment['external_reference'].inspect} " \
                          "mp_payment_id=#{mp_payment['id'].inspect}"
        return
      end

      update_local_payment_from_mp(payment, mp_payment)
    end

    def extract_mp_payment_id
      event.external_id.to_s.presence ||
        event.payload.dig("data", "id")&.to_s.presence ||
        event.payload["data.id"]&.to_s.presence ||
        (event.payload["data"].blank? ? event.payload["id"]&.to_s.presence : nil)
    end

    def fetch_mp_payment(mp_payment_id)
      result = sdk.payment.get(mp_payment_id)
      response = normalize_response(result)

      raise StandardError, "Mercado Pago não retornou response para payment.get" if response.blank?

      response
    end

    def normalize_response(result)
      return {} if result.nil?
      return result["response"] if result.is_a?(Hash) && result.key?("response")
      return result[:response] if result.is_a?(Hash) && result.key?(:response)
      result
    end

    # Três chaves de busca, em ordem de confiabilidade: o external_reference que
    # nós mesmos gravamos na preferência, o payment_id repetido em metadata (o
    # MP não propaga external_reference em 100% dos meios de pagamento) e, por
    # fim, o id do MP já persistido numa notificação anterior.
    def find_local_payment(mp_payment)
      by_uuid(mp_payment["external_reference"]) ||
        by_uuid(mp_payment.dig("metadata", "payment_id")) ||
        find_by_mp_payment_id(mp_payment["id"])
    end

    def by_uuid(value)
      reference = value.to_s
      return nil unless reference.match?(UUID_FORMAT)

      Payment.find_by(id: reference)
    end

    def find_by_mp_payment_id(mp_payment_id)
      return nil if mp_payment_id.blank?

      Payment.find_by(mercado_pago_payment_id: mp_payment_id.to_s)
    end

    def update_local_payment_from_mp(payment, mp_payment)
      if payment.one_off_message?
        handle_one_off_message_payment(payment, mp_payment)
      elsif payment.mimo_purchase?
        handle_mimo_purchase_payment(payment, mp_payment)
      elsif payment.wallet_deposit?
        handle_wallet_deposit_payment(payment, mp_payment)
      else
        handle_plan_purchase_payment(payment, mp_payment)
      end
    end

    # Compra de Mimo: approved credita a carteira do destinatário (MimoPaymentService.complete!);
    # rejected/cancelled marca a MimoTransaction como failed — o ledger nunca fica "pending" para sempre.
    def handle_mimo_purchase_payment(payment, mp_payment)
      mimo_transaction = payment.mimo_transaction
      return unless mimo_transaction

      case mp_payment["status"]
      when "approved"
        payment.approve!(mp_payment) if payment.may_approve?
        MimoPaymentService.complete!(mimo_transaction)
      when "pending", "in_process", "authorized"
        # PIX/boleto passam por aqui antes de compensar — registra o estado e espera.
        payment.pending!(mp_payment) if payment.may_pending?
      when "rejected", "cancelled"
        payment.reject!(mp_payment) if payment.may_reject?
        mimo_transaction.mark_failed! if mimo_transaction.may_mark_failed?
      end
    end

    # Depósito na carteira: approved credita o saldo do próprio usuário
    # (WalletDepositService.complete! — idempotente via payment.paid_at);
    # refunded/charged_back estorna o crédito (WalletDepositService.revert!).
    def handle_wallet_deposit_payment(payment, mp_payment)
      case mp_payment["status"]
      when "approved"
        payment.approve!(mp_payment) if payment.may_approve?
        WalletDepositService.complete!(payment)
      when "pending", "in_process", "authorized"
        # PIX nasce "pending": o MP notifica assim que o QR Code é gerado e de
        # novo quando o dinheiro compensa. Só o segundo evento credita.
        payment.pending!(mp_payment) if payment.may_pending?
      when "rejected", "cancelled"
        payment.reject!(mp_payment) if payment.may_reject?
      when "refunded", "charged_back"
        WalletDepositService.revert!(payment)
        payment.refund!(mp_payment) if payment.may_refund?
      end
    end

    # Pagamento avulso: só interessa o approved (crédita 1 mensagem via state machine)
    def handle_one_off_message_payment(payment, mp_payment)
      case mp_payment["status"]
      when "approved"
        payment.approve!(mp_payment) if payment.may_approve?
      when "rejected", "cancelled"
        payment.reject!(mp_payment) if payment.may_reject?
      end
    end

    # Compra de plano: fluxo original completo (approved, rejected, pending, refunded)
    def handle_plan_purchase_payment(payment, mp_payment)
      case mp_payment["status"]
      when "approved"
        payment.approve!(mp_payment) if payment.may_approve?
      when "rejected", "cancelled"
        payment.reject!(mp_payment) if payment.may_reject?
      when "pending"
        payment.pending!(mp_payment) if payment.may_pending?
      when "refunded", "charged_back"
        payment.refund!(mp_payment) if payment.may_refund?
      end
    end
  end
end
