class PagesController < ApplicationController
  before_action :authenticate_user!, only: [
    :mimo_catalog, :mimo_confirm, :mimo_celebration, :mimo_wallet, :mimo_withdraw, :mimo_deposit
  ]

  def landing
    redirect_to discover_3d_path if user_signed_in?
    @hide_layout_footer = true
  end

  def terms
  end

  def privacy
  end

  def suporte
  end

  # Guia de instalação do app iOS via TestFlight (beta)
  def testflight_guide
    @hide_layout_footer = true
    @seo_tags[:title]       = "Como instalar o GeoMatch no iPhone — TestFlight"
    @seo_tags[:description] = "Passo a passo para instalar a versão beta do GeoMatch no iPhone usando o TestFlight, o app oficial de betas da Apple."
  end

  # =========================================================
  # MIMOS (presentes virtuais) — views HTML/Stimulus que consomem os endpoints
  # JSON de MimosController/WalletsController (Fase 3) via fetch().
  # =========================================================

  # Catálogo de itens — o Stimulus controller busca os itens em /mimo_items/catalog.
  def mimo_catalog
    @hide_sidebar = true
    @receiver_id  = params[:receiver_id]
    @receiver     = User.find_by(id: @receiver_id)
  end

  # Tela de confirmação antes do checkout — recebe os dados do item escolhido
  # via query string (evita um round-trip extra à API só para exibir o card).
  # Aceita EXATAMENTE um destino: receiver_id (usuário já cadastrado) OU phone
  # (convite por SMS — ver MimoInviteService/MimoPaymentService, Fase 2/3).
  def mimo_confirm
    @hide_sidebar   = true
    @receiver_id    = params[:receiver_id].presence
    @receiver_phone = params[:phone].presence
    @receiver       = User.find(@receiver_id) if @receiver_id

    raise ActiveRecord::RecordNotFound if @receiver_id.blank? && @receiver_phone.blank?

    @mimo_item_id    = params.require(:mimo_item_id)
    @mimo_item_name  = params[:name]
    @mimo_item_price = params[:price_formatted]
    @mimo_item_icon  = params[:icon]
  rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound
    redirect_to mimo_catalog_page_path, alert: "Selecione um Mimo e um destinatário para continuar."
  end

  # Exibida quando o destinatário abre um Mimo recebido (ex.: a partir da notificação).
  def mimo_celebration
    @hide_sidebar     = true
    @mimo_transaction = MimoTransaction.find(params[:id])

    unless @mimo_transaction.receiver_id == current_user.id
      redirect_to mimo_wallet_page_path, alert: "Este Mimo não pertence a você." and return
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to mimo_wallet_page_path, alert: "Mimo não encontrado."
  end

  # Carteira digital — saldo e extrato carregados via /wallet e /wallet/transactions.
  def mimo_wallet
    @hide_sidebar = true
  end

  # Depósito de saldo — valores pré-definidos, envia para /wallet/deposit.
  def mimo_deposit
    @hide_sidebar = true
  end

  # Saque para PIX — envia para /wallet/withdraw.
  def mimo_withdraw
    @hide_sidebar = true
  end
end
