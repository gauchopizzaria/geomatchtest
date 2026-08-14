module MercadoPago
  class WebhookService
    require "mercadopago"

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

      if normalized_topic == 'payment'
        process_payment!
      end

      event.update!(status: 'processed', processed_at: Time.current)
    rescue StandardError => e
      event.update(
        status: 'failed', 
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

      mp_payment = fetch_mp_payment(mp_payment_id)

      find_local_payment(mp_payment).then do |payment|
        update_local_payment_from_mp(payment, mp_payment)
      end
    end

    def extract_mp_payment_id
      event.external_id.to_s.presence ||
        event.payload.dig("data", "id")&.to_s ||
        event.payload["id"]&.to_s
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

    def find_local_payment(mp_payment)
      Payment.find_by(id: mp_payment["external_reference"].to_s)
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
      when "rejected", "cancelled"
        payment.reject!(mp_payment) if payment.may_reject?
        mimo_transaction.mark_failed! if mimo_transaction.may_mark_failed?
      end
    end

    # Depósito na carteira: approved credita o saldo do próprio usuário
    # (WalletDepositService.complete! — idempotente via payment.paid_at);
    # rejected/cancelled só reflete o estado do Payment, não há saldo a estornar.
    def handle_wallet_deposit_payment(payment, mp_payment)
      case mp_payment["status"]
      when "approved"
        payment.approve!(mp_payment) if payment.may_approve?
        WalletDepositService.complete!(payment)
      when "rejected", "cancelled"
        payment.reject!(mp_payment) if payment.may_reject?
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
