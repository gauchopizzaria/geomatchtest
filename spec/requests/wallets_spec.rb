require "rails_helper"

RSpec.describe "Wallets", type: :request do
  let(:user) { create(:user, onboarding_completed: true) }

  # Os clientes reais (wallet_controller.js e o app nativo) sempre pedem JSON —
  # sem isso o ApplicationController trata o request como HTML.
  let(:json_headers) { { "ACCEPT" => "application/json" } }

  def deposit(paid_at: nil, state: "created", amount_cents: 5_000)
    Payment.create!(
      user: user,
      payment_type: "wallet_deposit",
      deposit_amount_cents: amount_cents,
      state: state,
      paid_at: paid_at
    )
  end

  describe "GET /wallet" do
    it "requires authentication" do
      get "/wallet", headers: json_headers
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns the balance" do
      sign_in user, scope: :user
      user.create_wallet!(balance_cents: 4_200)

      get "/wallet", headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["balance_cents"]).to eq(4_200)
    end

    # O ponto central da correção: abrir a carteira já concilia contra o Mercado
    # Pago. Sem isso o saldo só subia se o webhook chegasse — e ele pode nunca chegar.
    it "credits an uncredited deposit before answering" do
      sign_in user, scope: :user
      pending_deposit = deposit(state: "pending")

      allow(WalletDepositService).to receive(:sync!) do |p|
        p.user.wallet.update!(balance_cents: 500)
      end
      user.create_wallet!(balance_cents: 0)

      get "/wallet", headers: json_headers

      expect(WalletDepositService).to have_received(:sync!).with(pending_deposit)
      expect(response.parsed_body["balance_cents"]).to eq(500)
    end

    it "does not call Mercado Pago when there is nothing pending" do
      sign_in user, scope: :user
      user.create_wallet!(balance_cents: 4_200)
      allow(WalletDepositService).to receive(:sync!)

      get "/wallet", headers: json_headers

      expect(WalletDepositService).not_to have_received(:sync!)
    end

    # Saldo é dado vivo — um 304 servindo corpo antigo mostraria R$ 0,00 depois
    # de o depósito já ter sido creditado.
    it "forbids caching the balance" do
      sign_in user, scope: :user
      user.create_wallet!(balance_cents: 4_200)

      get "/wallet", headers: json_headers

      expect(response.headers["Cache-Control"]).to include("no-store")
    end
  end

  describe "GET /wallet/transactions" do
    before { sign_in user, scope: :user }

    # Sem esta linha o saldo subia sem nenhuma contrapartida no histórico e o
    # usuário não tinha como conferir se o PIX que pagou virou saldo.
    it "lists credited deposits in the statement" do
      deposit(paid_at: Time.current, state: "approved", amount_cents: 5_000)

      get "/wallet/transactions", headers: json_headers

      entry = response.parsed_body["transactions"].find { |t| t["type"] == "deposit" }
      expect(entry).to be_present
      expect(entry["amount_cents"]).to eq(5_000)
      expect(entry["description"]).to eq("Depósito via Mercado Pago")
    end

    it "omits deposits that were not credited yet" do
      deposit(state: "pending")

      get "/wallet/transactions", headers: json_headers

      expect(response.parsed_body["transactions"]).to be_empty
    end
  end

  describe "POST /wallet/reconcile" do
    before { sign_in user, scope: :user }

    it "syncs the user's uncredited deposits and returns the fresh balance" do
      pending_deposit = deposit(state: "pending")

      allow(WalletDepositService).to receive(:sync!) do
        user.wallet.update!(balance_cents: 5_000)
      end

      user.create_wallet!(balance_cents: 0)

      post "/wallet/reconcile", headers: json_headers

      expect(WalletDepositService).to have_received(:sync!).with(pending_deposit)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["balance_cents"]).to eq(5_000)
      expect(response.parsed_body["reconciled"]).to eq(1)
    end

    it "never touches another user's deposits" do
      other = create(:user)
      Payment.create!(user: other, payment_type: "wallet_deposit", deposit_amount_cents: 9_900, state: "pending")

      allow(WalletDepositService).to receive(:sync!)

      post "/wallet/reconcile", headers: json_headers

      expect(WalletDepositService).not_to have_received(:sync!)
      expect(response.parsed_body["reconciled"]).to eq(0)
    end

    it "still answers with the balance when Mercado Pago is unreachable" do
      deposit(state: "pending")
      user.create_wallet!(balance_cents: 700)
      allow(WalletDepositService).to receive(:sync!).and_raise(StandardError, "MP fora do ar")

      post "/wallet/reconcile", headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["balance_cents"]).to eq(700)
    end
  end
end
