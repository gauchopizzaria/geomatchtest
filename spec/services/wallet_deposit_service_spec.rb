require "rails_helper"

RSpec.describe WalletDepositService do
  let(:user) { create(:user) }

  def build_deposit(amount_cents: 5_000, **attrs)
    Payment.create!(
      user: user,
      payment_type: "wallet_deposit",
      deposit_amount_cents: amount_cents,
      **attrs
    )
  end

  describe ".complete!" do
    it "credits the user's own wallet with the deposited amount" do
      payment = build_deposit(amount_cents: 5_000)

      described_class.complete!(payment)

      expect(user.reload.wallet.balance_cents).to eq(5_000)
      expect(payment.reload.paid_at).to be_present
    end

    it "creates the wallet when the user does not have one yet" do
      payment = build_deposit(amount_cents: 2_000)
      expect(user.wallet).to be_nil

      described_class.complete!(payment)

      expect(user.reload.wallet.balance_cents).to eq(2_000)
    end

    it "adds to an existing balance instead of replacing it" do
      user.create_wallet!(balance_cents: 1_500)
      payment = build_deposit(amount_cents: 2_000)

      described_class.complete!(payment)

      expect(user.reload.wallet.balance_cents).to eq(3_500)
    end

    # Idempotência: o MP reenvia a mesma notificação várias vezes.
    it "does not credit twice for the same payment" do
      payment = build_deposit(amount_cents: 5_000)

      described_class.complete!(payment)
      described_class.complete!(payment)
      described_class.complete!(payment.reload)

      expect(user.reload.wallet.balance_cents).to eq(5_000)
    end

    it "does not count as earnings (lifetime_earned_cents is for Mimos received)" do
      payment = build_deposit(amount_cents: 5_000)

      described_class.complete!(payment)

      expect(user.reload.wallet.lifetime_earned_cents).to eq(0)
    end

    # Falha visível: engolir o erro fazia o WebhookEvent ser marcado como
    # "processed" mesmo sem crédito nenhum, e o depósito sumia sem rastro.
    it "raises when the payment has no deposit amount" do
      payment = build_deposit(amount_cents: nil)

      expect { described_class.complete!(payment) }.to raise_error(described_class::CreditError)
      expect(payment.reload.paid_at).to be_nil
    end

    it "refuses payments that are not wallet deposits" do
      payment = create(:payment)

      expect { described_class.complete!(payment) }.to raise_error(described_class::CreditError)
    end
  end

  describe ".revert!" do
    it "debits the credited amount back" do
      payment = build_deposit(amount_cents: 5_000)
      described_class.complete!(payment)

      described_class.revert!(payment)

      expect(user.reload.wallet.balance_cents).to eq(0)
      expect(payment.reload.paid_at).to be_nil
    end

    it "is a no-op for a deposit that was never credited" do
      payment = build_deposit(amount_cents: 5_000)
      user.create_wallet!(balance_cents: 900)

      described_class.revert!(payment)

      expect(user.reload.wallet.balance_cents).to eq(900)
    end

    it "debits what it can and records a reconciliation for the rest" do
      payment = build_deposit(amount_cents: 5_000)
      described_class.complete!(payment)
      user.reload.wallet.update!(balance_cents: 2_000) # usuário já gastou parte

      expect { described_class.revert!(payment) }.to change(WalletReconciliation, :count).by(1)

      expect(user.reload.wallet.balance_cents).to eq(0)
      # negativo = faltou debitar (semântica de discrepancy_cents no model)
      expect(WalletReconciliation.last.discrepancy_cents).to eq(-3_000)
    end

    it "never debits what is already reserved in a pending withdrawal" do
      payment = build_deposit(amount_cents: 5_000)
      described_class.complete!(payment)
      user.reload.wallet.update!(pending_withdrawal_cents: 4_000)

      described_class.revert!(payment)

      expect(user.reload.wallet.balance_cents).to eq(4_000)
    end
  end

  describe ".sync!" do
    let(:sdk)     { instance_double(Mercadopago::SDK) }
    let(:payment_resource) { double("payment_resource") }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("MERCADO_PAGO_ACCESS_TOKEN").and_return("token")
      allow(Mercadopago::SDK).to receive(:new).and_return(sdk)
      allow(sdk).to receive(:payment).and_return(payment_resource)
    end

    # O cenário do bug: o dinheiro caiu no MP mas a notificação nunca chegou.
    it "credits the wallet when Mercado Pago already has the payment approved" do
      payment = build_deposit(amount_cents: 5_000)
      allow(payment_resource).to receive(:search).and_return(
        { "response" => { "results" => [ { "id" => 42, "status" => "approved", "external_reference" => payment.id } ] } }
      )

      described_class.sync!(payment)

      expect(user.reload.wallet.balance_cents).to eq(5_000)
      expect(payment.reload).to be_approved
    end

    it "leaves the balance untouched while the PIX is still pending" do
      payment = build_deposit(amount_cents: 5_000)
      allow(payment_resource).to receive(:search).and_return(
        { "response" => { "results" => [ { "id" => 42, "status" => "pending", "external_reference" => payment.id } ] } }
      )

      described_class.sync!(payment)

      expect(user.reload.wallet&.balance_cents.to_i).to eq(0)
      expect(payment.reload).to be_pending
    end

    it "does not call Mercado Pago again for an already credited deposit" do
      payment = build_deposit(amount_cents: 5_000)
      described_class.complete!(payment)

      expect(payment_resource).not_to receive(:search)
      described_class.sync!(payment)

      expect(user.reload.wallet.balance_cents).to eq(5_000)
    end

    it "prefers the approved attempt when the checkout produced several" do
      payment = build_deposit(amount_cents: 5_000)
      allow(payment_resource).to receive(:search).and_return(
        { "response" => { "results" => [
          { "id" => 1, "status" => "rejected",  "date_created" => "2026-08-01T10:00:00Z" },
          { "id" => 2, "status" => "approved",  "date_created" => "2026-08-01T09:00:00Z" }
        ] } }
      )

      described_class.sync!(payment)

      expect(user.reload.wallet.balance_cents).to eq(5_000)
      expect(payment.reload.mercado_pago_payment_id).to eq("2")
    end
  end

  describe ".call" do
    it "rejects amounts below the minimum" do
      expect { described_class.call(user: user, amount_cents: 100) }
        .to raise_error(ArgumentError, /valor mínimo/)
    end
  end
end
