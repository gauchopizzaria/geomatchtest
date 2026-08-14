require "rails_helper"

RSpec.describe WithdrawalService do
  let(:user) { create(:user) }

  describe "valor mínimo de saque" do
    it "é R$ 5,00" do
      expect(described_class::MINIMUM_AMOUNT_CENTS).to eq(500)
    end

    it "aceita um saque de exatamente R$ 5,00" do
      user.create_wallet!(balance_cents: 500, pix_key: "chave@pix.com", pix_key_type: "email")

      request = described_class.request!(user: user, amount_cents: 500)

      expect(request).to be_persisted
      expect(request.amount_cents).to eq(500)
      expect(user.reload.wallet.pending_withdrawal_cents).to eq(500)
    end

    it "recusa abaixo do mínimo" do
      user.create_wallet!(balance_cents: 10_000, pix_key: "chave@pix.com", pix_key_type: "email")

      expect { described_class.request!(user: user, amount_cents: 499) }
        .to raise_error(described_class::MinimumAmountError, /R\$ 5,00/)
    end
  end

  describe "regras que continuam valendo" do
    before { user.create_wallet!(balance_cents: 1_000, pix_key: "chave@pix.com", pix_key_type: "email") }

    it "recusa saque maior que o saldo disponível" do
      expect { described_class.request!(user: user, amount_cents: 2_000) }
        .to raise_error(described_class::InsufficientBalanceError)
    end

    it "recusa um segundo saque dentro de 24h" do
      described_class.request!(user: user, amount_cents: 500)

      expect { described_class.request!(user: user, amount_cents: 500) }
        .to raise_error(described_class::RateLimitedError)
    end

    it "exige chave PIX cadastrada" do
      user.wallet.update!(pix_key: nil, pix_key_type: nil)

      expect { described_class.request!(user: user, amount_cents: 500) }
        .to raise_error(described_class::MissingPixKeyError)
    end
  end
end
