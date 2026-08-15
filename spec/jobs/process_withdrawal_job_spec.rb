require "rails_helper"

RSpec.describe ProcessWithdrawalJob do
  let(:admin) { create(:user, admin: true) }
  let(:user)  { create(:user) }

  def approved_withdrawal(amount_cents: 2_340)
    user.create_wallet!(balance_cents: amount_cents, pix_key: "chave@pix.com", pix_key_type: "email")
    request = WithdrawalService.request!(user: user, amount_cents: amount_cents)
    request.update!(processed_by: admin)
    request.approve!
    request
  end

  before do
    # A tesouraria interna não é o objeto destes testes e não pode fazer HTTP.
    allow(MpTransferService).to receive(:call)
  end

  it "só dá baixa no saldo quando o provedor CONFIRMA o envio do PIX" do
    request = approved_withdrawal
    allow(PixPayoutService).to receive(:call).and_return(
      PixPayoutService::Result.new(status: :succeeded, external_id: "payout-1")
    )

    described_class.new.perform(request.id)

    wallet = user.reload.wallet
    expect(request.reload).to be_paid
    expect(wallet.balance_cents).to eq(0)
    expect(wallet.pending_withdrawal_cents).to eq(0)
    expect(wallet.lifetime_withdrawn_cents).to eq(2_340)
  end

  # O caso perigoso: dar baixa num PIX que ainda não saiu faria o usuário perder
  # o dinheiro. O valor tem que continuar reservado.
  it "NÃO dá baixa enquanto o payout está em processamento" do
    request = approved_withdrawal
    allow(PixPayoutService).to receive(:call).and_return(
      PixPayoutService::Result.new(status: :pending, external_id: "payout-1")
    )

    described_class.new.perform(request.id)

    expect(request.reload).to be_approved
    expect(user.reload.wallet.balance_cents).to eq(2_340)
    expect(user.wallet.pending_withdrawal_cents).to eq(2_340)
  end

  it "NÃO dá baixa quando o payout falha" do
    request = approved_withdrawal
    allow(PixPayoutService).to receive(:call).and_return(
      PixPayoutService::Result.new(status: :failed, error: "chave pix inválida")
    )

    described_class.new.perform(request.id)

    expect(request.reload).to be_approved
    expect(user.reload.wallet.balance_cents).to eq(2_340)
  end

  # Modo manual (padrão): comportamento histórico preservado.
  it "deixa o saque aprovado aguardando envio manual quando não há provedor" do
    request = approved_withdrawal
    allow(PixPayoutService).to receive(:call).and_return(PixPayoutService::Result.new(status: :skipped))

    described_class.new.perform(request.id)

    expect(request.reload).to be_approved
    expect(user.reload.wallet.balance_cents).to eq(2_340)
  end

  it "ignora solicitações que não estão aprovadas" do
    user.create_wallet!(balance_cents: 2_340, pix_key: "chave@pix.com", pix_key_type: "email")
    request = WithdrawalService.request!(user: user, amount_cents: 2_340)

    expect(PixPayoutService).not_to receive(:call)
    described_class.new.perform(request.id)

    expect(request.reload).to be_pending
  end

  # MpTransferService sem contas configuradas não pode travar o saque.
  it "segue para o payout mesmo se a transferência interna não estiver configurada" do
    request = approved_withdrawal
    allow(MpTransferService).to receive(:call).and_raise(MpTransferService::ConfigurationError, "contas não configuradas")
    allow(PixPayoutService).to receive(:call).and_return(
      PixPayoutService::Result.new(status: :succeeded, external_id: "payout-1")
    )

    described_class.new.perform(request.id)

    expect(request.reload).to be_paid
  end
end
