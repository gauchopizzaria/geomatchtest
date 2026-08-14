require "rails_helper"

RSpec.describe "Mercado Pago Webhooks", type: :request do
  describe "POST /webhooks/mercado_pago" do
    before { allow(MercadoPago::WebhookService).to receive(:call) }

    it "creates a WebhookEvent and returns accepted" do
      payload = { type: "payment", action: "payment.updated", data: { id: "123456789" } }

      expect do
        post "/webhooks/mercado_pago",
             params: payload.to_json,
             headers: { "CONTENT_TYPE" => "application/json" }
      end.to change(WebhookEvent, :count).by(1)

      expect(response).to have_http_status(:accepted)
      event = WebhookEvent.last
      expect(event.source).to eq("mercadopago")
      expect(event.topic).to eq("payment")
      expect(event.external_id).to eq("123456789")
      expect(event.status).to eq("pending")
      expect(MercadoPago::WebhookService).to have_received(:call).with(event: event)
    end

    it "reads the MP action from the body, not from params[:action]" do
      payload = { type: "payment", action: "payment.updated", data: { id: "1" } }

      post "/webhooks/mercado_pago",
           params: payload.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }

      # params[:action] é sempre o nome da action do controller ("create").
      expect(WebhookEvent.last.action).to eq("payment.updated")
    end

    # Formato IPN legado — é o que o MP envia quando o notification_url é
    # declarado na preferência (MimoPaymentService / WalletDepositService).
    # Corpo VAZIO, tudo na query string. Era aqui que o depósito via PIX morria.
    it "accepts the legacy IPN format (?topic=payment&id=N) with an empty body" do
      expect do
        post "/webhooks/mercado_pago?topic=payment&id=987654321"
      end.to change(WebhookEvent, :count).by(1)

      expect(response).to have_http_status(:accepted)
      event = WebhookEvent.last
      expect(event.topic).to eq("payment")
      expect(event.external_id).to eq("987654321")
      expect(event.payload).to be_present
    end

    # Formato v2 por query string: o Rails não aninha "data.id", a chave é literal.
    it "accepts the v2 query-string format (?type=payment&data.id=N)" do
      post "/webhooks/mercado_pago?type=payment&data.id=555&action=payment.updated"

      expect(response).to have_http_status(:accepted)
      event = WebhookEvent.last
      expect(event.topic).to eq("payment")
      expect(event.external_id).to eq("555")
      expect(event.action).to eq("payment.updated")
    end

    it "ignores the top-level notification id when the v2 body carries data.id" do
      payload = { type: "payment", id: 111, data: { id: "222" } }

      post "/webhooks/mercado_pago",
           params: payload.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }

      expect(WebhookEvent.last.external_id).to eq("222")
    end

    it "returns bad_request for invalid JSON" do
      post "/webhooks/mercado_pago",
           params: "{invalid",
           headers: { "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:bad_request)
    end
  end
end
