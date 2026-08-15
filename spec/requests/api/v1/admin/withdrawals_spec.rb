require "rails_helper"

RSpec.describe "Api::V1::Admin::Withdrawals", type: :request do
  let(:admin) { create(:user, admin: true) }
  let(:user)  { create(:user) }

  let(:auth_headers) do
    { "Authorization" => "Bearer #{JwtService.encode(sub: admin.id)}", "ACCEPT" => "application/json" }
  end

  # Saldo suficiente + chave PIX salva para o pedido nascer válido.
  def request_withdrawal(amount_cents: 2_340)
    user.create_wallet!(balance_cents: amount_cents, pix_key: "chave@pix.com", pix_key_type: "email")
    WithdrawalService.request!(user: user, amount_cents: amount_cents)
  end

  describe "GET /api/v1/admin/withdrawals" do
    it "lists the requests with the user and pix key" do
      withdrawal = request_withdrawal

      get "/api/v1/admin/withdrawals", headers: auth_headers

      expect(response).to have_http_status(:ok)
      listed = response.parsed_body["withdrawals"].first
      expect(listed["id"]).to eq(withdrawal.id)
      expect(listed["status"]).to eq("pending")
      expect(listed["pix_key"]).to eq("chave@pix.com")
      expect(listed["user"]["email"]).to eq(user.email)
    end

    it "denies access to non-admins" do
      headers = { "Authorization" => "Bearer #{JwtService.encode(sub: user.id)}", "ACCEPT" => "application/json" }

      get "/api/v1/admin/withdrawals", headers: headers

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PATCH /api/v1/admin/withdrawals/:id/approve" do
    # Era o elo que faltava: sem esta rota o pedido ficava "pending" para sempre.
    it "approves the request and enqueues the processing job" do
      withdrawal = request_withdrawal

      expect {
        patch "/api/v1/admin/withdrawals/#{withdrawal.id}/approve", headers: auth_headers
      }.to have_enqueued_job(ProcessWithdrawalJob)

      expect(response).to have_http_status(:ok)
      expect(withdrawal.reload).to be_approved
      expect(withdrawal.processed_by).to eq(admin)
    end

    it "refuses to approve twice" do
      withdrawal = request_withdrawal
      patch "/api/v1/admin/withdrawals/#{withdrawal.id}/approve", headers: auth_headers

      patch "/api/v1/admin/withdrawals/#{withdrawal.id}/approve", headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "PATCH /api/v1/admin/withdrawals/:id/reject" do
    it "returns the reserved amount to the available balance" do
      withdrawal = request_withdrawal(amount_cents: 2_340)
      expect(user.reload.wallet.available_balance_cents).to eq(0)

      patch "/api/v1/admin/withdrawals/#{withdrawal.id}/reject",
            params: { reason: "chave inválida" }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(withdrawal.reload).to be_rejected
      expect(user.reload.wallet.available_balance_cents).to eq(2_340)
    end
  end

  describe "PATCH /api/v1/admin/withdrawals/:id/mark_paid" do
    it "debits the balance for good" do
      withdrawal = request_withdrawal(amount_cents: 2_340)
      patch "/api/v1/admin/withdrawals/#{withdrawal.id}/approve", headers: auth_headers

      patch "/api/v1/admin/withdrawals/#{withdrawal.id}/mark_paid", headers: auth_headers

      expect(response).to have_http_status(:ok)
      wallet = user.reload.wallet
      expect(withdrawal.reload).to be_paid
      expect(wallet.balance_cents).to eq(0)
      expect(wallet.pending_withdrawal_cents).to eq(0)
      expect(wallet.lifetime_withdrawn_cents).to eq(2_340)
    end

    it "refuses when the request was not approved" do
      withdrawal = request_withdrawal

      patch "/api/v1/admin/withdrawals/#{withdrawal.id}/mark_paid", headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
