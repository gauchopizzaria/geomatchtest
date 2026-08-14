require "rails_helper"

RSpec.describe ReconcilePendingDepositsJob do
  let(:user) { create(:user) }

  def deposit(state: "created", paid_at: nil, created_at: Time.current, amount_cents: 5_000)
    Payment.create!(
      user: user,
      payment_type: "wallet_deposit",
      deposit_amount_cents: amount_cents,
      state: state,
      paid_at: paid_at,
      created_at: created_at
    )
  end

  describe ".pending_scope" do
    it "picks up deposits that were never credited" do
      created = deposit(state: "created")
      pending = deposit(state: "pending")

      expect(described_class.pending_scope).to contain_exactly(created, pending)
    end

    it "ignores deposits that were already credited" do
      deposit(state: "approved", paid_at: Time.current)

      expect(described_class.pending_scope).to be_empty
    end

    it "ignores terminal states and other payment types" do
      deposit(state: "rejected")
      deposit(state: "refunded")
      create(:payment)

      expect(described_class.pending_scope).to be_empty
    end

    it "ignores deposits older than the lookback window" do
      deposit(created_at: 8.days.ago)

      expect(described_class.pending_scope).to be_empty
    end
  end

  describe "#perform" do
    it "syncs each pending deposit against Mercado Pago" do
      first  = deposit
      second = deposit

      allow(WalletDepositService).to receive(:sync!)

      described_class.new.perform

      expect(WalletDepositService).to have_received(:sync!).with(first)
      expect(WalletDepositService).to have_received(:sync!).with(second)
    end

    # Um depósito problemático não pode impedir a conciliação dos outros.
    it "keeps going when one deposit blows up" do
      broken = deposit
      healthy = deposit

      allow(WalletDepositService).to receive(:sync!).with(broken).and_raise(StandardError, "boom")
      allow(WalletDepositService).to receive(:sync!).with(healthy)

      expect { described_class.new.perform }.not_to raise_error
      expect(WalletDepositService).to have_received(:sync!).with(healthy)
    end
  end
end
