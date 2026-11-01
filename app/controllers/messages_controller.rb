class MessagesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_match

  wrap_parameters format: []

  def index
    @messages = @match.messages.order(created_at: :asc)

    render json: @messages.map { |m|
      {
        id: m.id,
        content: m.content,
        sender_id: m.sender_id,
        reply_to_id: m.reply_to_id,
        created_at: m.created_at.iso8601
      }
    }
  end

  def create
    unless @match.participant?(current_user)
      return head :forbidden
    end

    @message = @match.messages.build(message_params)
    @message.sender = current_user
    @message.reply_to = quoted_message

    if @message.save
      render json: @message.as_json(only: [:id, :content, :sender_id, :reply_to_id, :created_at])
    else
      render json: { errors: @message.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /matches/:match_id/messages/:id
  # Apenas o remetente pode apagar a própria mensagem
  def destroy
    @message = @match.messages.find(params[:id])

    unless @message.sender_id == current_user.id
      return head :forbidden
    end

    @message.destroy # after_destroy_commit broadcasts { deleted_message_id: id }
    head :ok
  end

  # POST /matches/:match_id/messages/:id/react
  # Toggle/Replace a reação do usuário nessa mensagem
  def react
    @message = @match.messages.find(params[:id])
    emoji    = params[:emoji].to_s.strip

    return head :unprocessable_entity if emoji.blank?

    existing = @message.reactions.find_by(user: current_user)

    if existing
      existing.emoji == emoji ? existing.destroy : existing.update!(emoji: emoji)
    else
      @message.reactions.create!(user: current_user, emoji: emoji)
    end

    counts = @message.reactions.group(:emoji).count
    MatchChannel.broadcast_to(@match, {
      reaction: { message_id: @message.id, counts: counts }
    })

    render json: { counts: counts }
  end

  private

  def set_match
    @match = Match.find(params[:match_id])
  end

  def message_params
    params.require(:message).permit(:content)
  end

  # Mensagem citada ao responder (arrastar para a direita no chat). A busca é
  # limitada a esta conversa: id de outra conversa, inexistente ou de uma
  # mensagem apagada enquanto a pessoa digitava não impede o envio — a
  # mensagem sai normalmente, só sem a citação.
  def quoted_message
    reply_to_id = params.dig(:message, :reply_to_id)
    return nil if reply_to_id.blank?

    @match.messages.find_by(id: reply_to_id)
  end
end
