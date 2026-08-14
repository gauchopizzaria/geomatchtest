class User < ApplicationRecord
  # Devise
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :omniauthable, omniauth_providers: %i[google_oauth2]


 
  # Garante que os checkboxes foram marcados no cadastro
  validates :terms_of_use, acceptance: { message: 'devem ser aceitos para prosseguir.' }
  validates :data_policy, acceptance: { message: 'deve ser aceita para prosseguir.' }

  # --- Associações ---
  belongs_to :plan
  validates :plan, presence: true

  has_many :payments, dependent: :destroy
  has_one  :latest_approved_payment,
           -> { where(state: 'approved').order(created_at: :desc) },
           class_name: 'Payment'
  has_many :likes, foreign_key: :liker_id, dependent: :destroy
  has_many :push_subscriptions, dependent: :destroy
  
  # Matches
  has_many :matches_as_user, class_name: 'Match', foreign_key: 'user_id', dependent: :destroy
  has_many :matches_as_matched_user, class_name: 'Match', foreign_key: 'matched_user_id', dependent: :destroy
  
  has_many :notifications, foreign_key: :recipient_id, dependent: :destroy
  has_many :stories, dependent: :destroy
  has_many :blog_posts, dependent: :destroy

  has_many :favorites, dependent: :destroy
  has_many :favorited_users, through: :favorites, source: :favorited_user

  # =========================================================
  # BLOQUEIOS
  # =========================================================
  
  has_many :blocks_sent, class_name: 'Block', foreign_key: 'blocker_id', dependent: :destroy
  has_many :blocked_users, through: :blocks_sent, source: :blocked

  has_many :blocks_received, class_name: 'Block', foreign_key: 'blocked_id', dependent: :destroy
  has_many :blocked_by_users, through: :blocks_received, source: :blocker

  has_many :reports_sent, class_name: 'Report', foreign_key: :reporter_id, dependent: :destroy

  # Cupons resgatados por este usuário
  has_many :user_coupons, dependent: :destroy
  has_many :coupons, through: :user_coupons

  # =========================================================
  # MIMOS (carteira e presentes virtuais)
  # =========================================================
  has_one  :wallet, class_name: 'UserWallet', dependent: :destroy
  has_many :mimo_transactions_sent,     class_name: 'MimoTransaction', foreign_key: :sender_id,   dependent: :destroy
  has_many :mimo_transactions_received, class_name: 'MimoTransaction', foreign_key: :receiver_id, dependent: :destroy
  has_many :withdrawal_requests, dependent: :destroy

  # Atributo virtual — coupon_code chega junto do form de onboarding/perfil,
  # mas não é coluna do banco. Sem isto, permitir :coupon_code em user_params
  # quebraria o update com ActiveModel::UnknownAttributeError.
  attr_accessor :coupon_code

  # Active Storage
  has_one_attached :avatar
  has_one_attached :avatar_original
  has_one_attached :document_front
  has_one_attached :document_back
  has_one_attached :selfie_with_document
  has_many_attached :album_photos

  # Enum de escolaridade (coluna integer no banco)
  enum :education_level, {
    high_school:          0,
    college_incomplete:   1,
    college_complete:     2
  }

  # Geocoder — usa o campo :address, que é sincronizado a partir dos componentes
  geocoded_by :address
  before_validation :sync_address_from_components
  after_validation :geocode, if: ->(obj) { obj.address.present? && obj.will_save_change_to_address? }

  # =========================================================
  # OMNIAUTH — Google OAuth2
  # =========================================================

  # Chamado pelo callback controller para buscar usuário existente pelo par provider+uid.
  def self.from_omniauth(auth)
    find_by(provider: auth.provider, uid: auth.uid)
  end

  # Chamado pelo Devise::RegistrationsController#build_resource durante GET e POST
  # de /users/sign_up para mesclar dados do Google (armazenados na sessão) ao
  # resource sendo construído. Nunca sobrescreve o que o usuário já preencheu.
  def self.new_with_session(params, session)
    super.tap do |user|
      next unless (data = session["devise.google_data"])

      user.email    = data[:email]    if user.email.blank?
      user.username = data[:name]     if user.username.blank?
      user.provider = data[:provider]
      user.uid      = data[:uid]
    end
  end

  # --- Scopes ---
  scope :expired_premium, -> { 
    free_plan = Plan.find_by(name: 'Free')
    return none unless free_plan
    where.not(plan_id: free_plan.id).where('premium_until < ?', Time.current) 
  }
  
  scope :filter_by_age, ->(min, max) {
    return all if min.blank? || max.blank?
    start_date = (max.to_i + 1).years.ago.to_date + 1.day
    end_date   = min.to_i.years.ago.to_date
    where(birthdate: start_date..end_date)
  }

  scope :visible,       -> { where(invisible: [false, nil]) }
  # Filtra utilizadores ativos no mapa: só aparecem quem atualizou a localização
  # nos últimos 5 minutos. O heartbeat (presence.js) bate a cada 60s; o threshold
  # de 5 min tolera bloqueios breves de ecrã e quedas de rede temporárias.
  # Quem fechar o app sem fazer logout desaparece ao fim de 5 min de inatividade.
  scope :online_on_map, -> { where('last_location_updated_at >= ?', 5.minutes.ago) }
  
  # --- Callbacks ---
  after_create :attach_default_avatar
  before_validation :set_default_plan, on: :create

  # --- Métodos Públicos ---

  # =========================================================
  # REGRAS DOS PLANOS (ATUALIZADO)
  # =========================================================

  # 1. Pode usar o MODO INVISÍVEL?
  # Regra: Só Gold pode (ou se o JSON permitir explicitamente)
  def can_use_invisible_mode?
    features = (plan.features || {}).with_indifferent_access
    return true if features[:allow_invisible] == true
    
    plan.name == 'Gold'
  end

  # =========================================================
  # LÓGICA DE LIMITES (CORRIGIDA E BLINDADA)
  # =========================================================

  # 1. Verifica se pode dar LIKE
  def can_like?
    # O truque está aqui: .with_indifferent_access
    features = (plan.features || {}).with_indifferent_access

    # 1. Se for ilimitado (Plus ou Gold)
    return true if features[:likes_right_unlimited] == true

    # 2. Se tiver limite numérico (Free: 47)
    limit = features[:likes_right_limit]
    
    if limit.present?
      # Regra de Reset: 5 horas
      if last_like_reset_at.nil? || Time.current > (last_like_reset_at + 5.hours)
        reset_likes_counter!
      end
      
      # Verifica saldo atual
      return likes_count < limit.to_i
    end

    # FAILSAFE: Se o usuário é FREE e não achou limite, BLOQUEIA por padrão 47
    if plan.name == 'Free'
      return likes_count < 47
    end

    true
  end

  # 2. Incrementa o contador de LIKE
  def increment_likes!
    features = (plan.features || {}).with_indifferent_access
    
    unless features[:likes_right_unlimited] == true
      update(last_like_reset_at: Time.current) if likes_count == 0
      increment!(:likes_count)
    end
  end

  # 3. Verifica se pode enviar MENSAGEM
  def can_send_message?
    features = (plan.features || {}).with_indifferent_access
    dm_config = (features[:direct_messages] || {}).with_indifferent_access

    # --- REGRA 1: Plus e Gold são ILIMITADOS ---
    return true if ['Plus', 'Gold'].include?(plan.name)

    # --- REGRA 2: Créditos avulsos desbloqueiam envio para qualquer plano ---
    return true if one_off_message_credits > 0

    # --- REGRA 3: Free tem limite diário de 3 ---
    if plan.name == 'Free'
      limit = 3

      if last_message_reset_at.nil? || Time.current > (last_message_reset_at + 24.hours)
        reset_messages_counter!
      end

      return messages_count < limit
    end

    # Fallback: usa o JSON do banco
    return false if dm_config[:enabled] == false
    return true if features[:unlimited_messages] == true || dm_config[:daily_limit].nil?

    limit = dm_config[:daily_limit]
    if limit.present?
      if last_message_reset_at.nil? || Time.current > (last_message_reset_at + 24.hours)
        reset_messages_counter!
      end
      return messages_count < limit.to_i
    end

    true
  end

  # 4. Incrementa o contador de MENSAGEM (consome crédito avulso se houver)
  def increment_messages!
    features = (plan.features || {}).with_indifferent_access
    is_unlimited = ['Plus', 'Gold'].include?(plan.name) || features[:unlimited_messages] == true

    return if is_unlimited

    # Prioridade: consome crédito avulso antes do limite diário do plano
    if one_off_message_credits > 0
      use_message_credit!
    else
      update(last_message_reset_at: Time.current) if messages_count == 0
      increment!(:messages_count)
    end
  end

  # 5. Adiciona 1 crédito de mensagem avulsa (chamado após pagamento aprovado)
  def add_message_credit!
    increment!(:one_off_message_credits)
  end

  # 6. Consome 1 crédito de mensagem avulsa (só decrementa se houver saldo)
  def use_message_credit!
    return false unless one_off_message_credits > 0

    decrement!(:one_off_message_credits)
    true
  end

  # =========================================================

  def downgrade_to_free!
    free_plan = Plan.find_by(name: 'Free')
    return unless free_plan
    transaction do
      update!(plan: free_plan, premium_until: nil)
    end
  end

  def has_real_avatar?
    avatar.attached? && avatar.blob.filename.to_s != "avatarfoto.jpg"
  end

  def avatar_or_default
    if has_real_avatar?
      avatar
    elsif (first = album_photos.first)
      first
    else
      "avatarfoto.jpg"
    end
  end

  def avatar_url
    helpers = Rails.application.routes.url_helpers
    if has_real_avatar?
      helpers.url_for(avatar)
    elsif (first_album = album_photos.first)
      helpers.url_for(first_album)
    else
      ActionController::Base.helpers.asset_path("avatarfoto.jpg")
    end
  end

  def matches
    Match.where("user_id = ? OR matched_user_id = ?", id, id)
  end

  def excluded_user_ids
    blocked_users.pluck(:id) + blocked_by_users.pluck(:id)
  end

  def display_name
    if username.present?
      parts = username.split
      parts.size > 1 ? "#{parts.first} #{parts.last}" : parts.first
    else
      email&.split('@')&.first || "Usuário"
    end
  end
  
  def age
    return nil unless birthdate
    today = Date.current
    age_calc = today.year - birthdate.year
    age_calc -= 1 if today < birthdate + age_calc.years
    age_calc
  end

  def hobbies_list
    (hobbies || "").split(",")
  end

  def hobbies_list=(values)
    val_to_save = values.is_a?(String) ? values.split(',') : values
    self.hobbies = val_to_save.reject(&:blank?).join(",")
  end

  def online?
    last_seen_at.present? && last_seen_at > 2.minutes.ago
  end

  def premium?
    premium_until.present? && premium_until > Time.current
  end

  def banned?
    banned_at.present?
  end

  def ban!
    update!(banned_at: Time.current)
  end

  def unban!
    update!(banned_at: nil)
  end

  # Impede login via Devise se o usuário estiver banido
  def active_for_authentication?
    super && !banned?
  end

  def inactive_message
    banned? ? :banned : super
  end

  # =========================================================
  # PERMISSÕES DE VISUALIZAÇÃO (NOTIFICAÇÕES)
  # =========================================================

  # Verifica genericamente uma feature: premium (via cupom/pagamento) libera tudo,
  # senão consulta o JSON de features do plano.
  def has_feature?(feature_name)
    return true if premium?
    features = (plan.features || {}).with_indifferent_access
    features[feature_name] == true
  end

  # 1. Pode ver quem curtiu ELE? (Aba "Quem te curtiu")
  # Free: Não | Plus: Sim | Gold: Sim | Premium (cupom): Sim
  def can_see_who_liked_me?
    return true if premium?
    features = (plan.features || {}).with_indifferent_access
    features[:see_who_liked_me] == true
  end

  # 2. Pode ver quem ELE curtiu? (Aba "Você curtiu")
  # Free: Não | Plus: Sim | Gold: Sim | Premium (cupom): Sim
  def can_see_who_i_liked?
    return true if premium?
    features = (plan.features || {}).with_indifferent_access
    features[:see_who_i_liked] == true
  end

  # Free: Não | Plus: Não | Gold: Sim | Premium (cupom): Sim
  def can_rewind?
    return true if premium?
    features = (plan.features || {}).with_indifferent_access
    features[:rewind_profile] == true
  end

  # Free: Não | Plus: Não | Gold: Sim | Premium (cupom): Sim
  def can_search_by_distance?
    return true if premium?
    features = (plan.features || {}).with_indifferent_access
    features[:search_by_distance] == true
  end

  # =========================================================
  # CUPONS
  # =========================================================

  # Aplica um cupom ao usuário, concedendo dias de acesso premium.
  # Retorna { success: Boolean, message: String }.
  def apply_coupon(coupon_code)
    coupon = Coupon.active.find_by(code: coupon_code.to_s.strip.upcase)

    return { success: false, message: "Cupom inválido ou expirado." } unless coupon
    return { success: false, message: "Você já usou este cupom." } if user_coupons.exists?(coupon: coupon)
    return { success: false, message: "Limite de usos para este cupom atingido." } unless coupon.available?

    case coupon.discount_type
    when 'free_access'
      # Concede acesso premium por `duration_days`, estendendo a partir do maior
      # entre o premium atual (se ainda válido) e o momento presente.
      current_premium_until = premium_until || Time.current
      new_premium_until     = [current_premium_until, Time.current].max + coupon.duration_days.days

      transaction do
        update!(premium_until: new_premium_until)
        coupon.increment_usage!
        user_coupons.create!(coupon: coupon, applied_at: Time.current)
      end

      { success: true, message: "Cupom aplicado com sucesso! Você ganhou #{coupon.duration_days} dias de acesso premium." }
    else
      { success: false, message: "Tipo de cupom não suportado." }
    end
  rescue => e
    Rails.logger.error "Erro ao aplicar cupom #{coupon_code} para User##{id}: #{e.message}"
    { success: false, message: "Ocorreu um erro ao aplicar o cupom. Tente novamente." }
  end

  private

  # Monta o campo :address a partir dos componentes para o geocoder funcionar
  def sync_address_from_components
    parts = [street, neighborhood, city, state].compact_blank
    self.address = parts.join(", ") if parts.any?
  end

  def reset_likes_counter!
    update(likes_count: 0, last_like_reset_at: Time.current)
  end

  def reset_messages_counter!
    update(messages_count: 0, last_message_reset_at: Time.current)
  end

  def attach_default_avatar
    return if avatar.attached?
    default_path = Rails.root.join("app/assets/images/avatarfoto.jpg")

    if File.exist?(default_path)
      avatar.attach(io: File.open(default_path), filename: "avatarfoto.jpg", content_type: "image/jpeg")
    else
      Rails.logger.error "⚠️ ERRO: avatarfoto.jpg não encontrado em app/assets/images"
    end
  end

  def set_default_plan
    self.plan ||= Plan.find_by(name: "Free") 
  end

end