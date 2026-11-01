class MatchesController < ApplicationController
  before_action :authenticate_user!
  # Define @match apenas para actions específicas e garante segurança
  before_action :set_match, only: [:show, :clear_conversation]

  def index
    # 1. IDs dos matches com mensagem, ordenados pela mais recente.
    # Colunas qualificadas (messages.match_id) para evitar ambiguidade com matches.id no JOIN.
    initiated_ids_ordered = Message
      .joins(:match)
      .where("matches.user_id = ? OR matches.matched_user_id = ?", current_user.id, current_user.id)
      .group("messages.match_id")
      .order(Arel.sql("MAX(messages.created_at) DESC"))
      .pluck("messages.match_id")

    # 2. Carrega matches iniciados preservando a ordem
    avatar_includes = { avatar_attachment: :blob, album_photos_attachments: :blob }
    user_photo_includes = { user: avatar_includes, matched_user: avatar_includes }

    @matches_initiated = if initiated_ids_ordered.any?
      matches_hash = Match.where(id: initiated_ids_ordered)
                          .includes(user_photo_includes)
                          .index_by(&:id)
      initiated_ids_ordered.map { |id| matches_hash[id] }.compact
    else
      []
    end

    # 3. Matches não iniciados (mútuos via likes) — Match.where direto para evitar
    # qualquer pegadinha de chaining sobre o helper current_user.matches.
    @matches_uninitiated = Match
      .where("user_id = ? OR matched_user_id = ?", current_user.id, current_user.id)
      .where.not(id: initiated_ids_ordered)
      .includes(user_photo_includes)
      .select do |match|
        other = match.other_user(current_user)
        next false if other.nil?
        Like.exists?(liker_id: current_user.id, liked_id: other.id) &&
          Like.exists?(liker_id: other.id, liked_id: current_user.id)
      end
  end

  def show
    # reply_to: :sender — cada resposta desenha a citação (autor + trecho) sem N+1
    @messages = @match.messages.includes(reply_to: :sender).order(created_at: :asc)
    @message  = Message.new
    @other_user = @match.other_user(current_user)

    if @other_user.nil?
      redirect_to matches_path, alert: "Usuário não encontrado."
      return
    end
  end

  def start_chat
    target_user = User.find(params[:user_id])

    # ... (verificação de bloqueio mantida) ...

    # VERIFICAÇÃO DE LIMITE (Free = 7, Outros = Ilimitado)
    unless current_user.can_send_message?
      respond_to do |format|
        format.turbo_stream { 
          # Renderiza o modal passando type: 'messages'
          render turbo_stream: turbo_stream.update("upgrade-modal-container", 
                 partial: "shared/upgrade_modal", 
                 locals: { type: 'messages' }) 
        }
        format.html { redirect_to lead_path, alert: "Limite atingido! Pague #{Setting.one_off_message_price_formatted} ou faça upgrade." }
      end
      return
    end

    current_user.increment_messages!

    # 5. Busca ou cria o match
    @match = Match.where(user: current_user, matched_user: target_user)
                  .or(Match.where(user: target_user, matched_user: current_user))
                  .first

    unless @match
      @match = Match.create!(user: current_user, matched_user: target_user)
    end

    redirect_to match_path(@match)

  rescue ActiveRecord::RecordNotFound
    redirect_to lead_path, alert: "Usuário não encontrado."
  end

 def clear_conversation
  if @match.messages.destroy_all
    respond_to do |format|
      # Se for um acesso normal (fallback)
      format.html { redirect_to match_path(@match), notice: "Conversa limpa." }
      # Se for via AJAX (o que o seu JS vai usar)
      format.json { head :no_content } 
    end
  else
    respond_to do |format|
      format.html { redirect_to match_path(@match), alert: "Erro ao limpar." }
      format.json { render json: { error: "Erro" }, status: :unprocessable_entity }
    end
  end
end

  private

  # Método de segurança: Garante que o Match pertence ao usuário logado
  def set_match
    @match = current_user.matches.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to matches_path, alert: "Conversa não encontrada ou acesso negado."
  end
end