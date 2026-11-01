require "rails_helper"

RSpec.describe "Curtidas (/notifications)", type: :request do
  # A factory padrão de Plan usa "see_who_liked"; o código lê "see_who_liked_me".
  let(:full_plan) { create(:plan, features: { "see_who_liked_me" => true, "likes_right_unlimited" => true }) }
  let(:free_plan) { create(:plan, :free) }
  let(:me)        { create(:user, onboarding_completed: true, plan: full_plan) }

  before do
    allow(NotificationBroadcastJob).to receive(:perform_later)
  end

  def person(name)
    create(:user, username: name, onboarding_completed: true)
  end

  def liked_by(actor, recipient: me, at: Time.current)
    like = Like.create!(liker: actor, liked: recipient)
    Notification.create!(recipient: recipient, actor: actor, action: "curtiu seu perfil", notifiable: like, created_at: at)
  end

  def open_page(as: me)
    sign_in as, scope: :user
    get "/notifications"
    response.body
  end

  describe "lista de quem te curtiu" do
    it "mostra cada pessoa uma vez e deixa de fora bloqueados e o que não é curtida (ex.: Mimo)" do
      ana = person("Ana Souza")
      liked_by(ana, at: 2.days.ago)
      match = Match.create!(user: me, matched_user: ana, status: "matched")
      Notification.create!(recipient: me, actor: ana, action: "vocês deram match!", notifiable: match)

      bia = person("Bia Lima")
      liked_by(bia)
      Block.create!(blocker: me, blocked: bia)

      carla = person("Carla Dias")
      Notification.create!(recipient: me, actor: carla, action: "te enviou um Mimo", notifiable: carla)

      body = open_page

      expect(body.scan("data-notification-id=").size).to eq(1)
      expect(body).to include('<span class="likes-tab-count">1</span>')
      expect(body).to include("Ana")
      expect(body).not_to include("Bia")
      expect(body).not_to include("Carla")
    end

    it "mostra em \"Novas hoje\" só quem curtiu hoje" do
      liked_by(person("Ana Souza"))
      liked_by(person("Eva Rocha"), at: 3.days.ago)

      body = open_page
      today_strip = body[/<div class="likes-today">.*?<div class="likes-grid">/m]

      expect(today_strip).to include("1 nova")
      expect(today_strip).to include("Ana")
      expect(today_strip).not_to include("Eva")
      expect(body.scan("data-notification-id=").size).to eq(2)
    end
  end

  describe "coração de curtir de volta" do
    it "envia a curtida pela própria tela quando você ainda não curtiu a pessoa" do
      ana = person("Ana Souza")
      liked_by(ana)

      body = open_page

      expect(body).to match(%r{<form class="like-card-heart-form" method="post" action="/likes"})
      expect(body).to include(%(name="user_id" value="#{ana.id}"))
      expect(body).to include('name="source" value="likes"')
    end

    it "leva para a conversa quando já deu match" do
      dani = person("Dani Alves")
      liked_by(dani)
      Like.create!(liker: me, liked: dani)
      match = Match.create!(user: me, matched_user: dani, status: "matched")

      body = open_page

      expect(body).to include(%(href="/matches/#{match.id}"))
      expect(body).to match(/class="like-card-heart is-liked"/)
      expect(body).not_to include('action="/likes"')
    end
  end

  describe "plano que não mostra quem curtiu" do
    let(:free_me) { create(:user, onboarding_completed: true, plan: free_plan) }

    it "não revela nome nem permite curtir de volta (curtir mostraria a pessoa no match)" do
      liked_by(person("Ana Souza"), recipient: free_me)

      body = open_page(as: free_me)

      expect(body).not_to include("Ana")
      expect(body).to include("Alguém")
      expect(body).not_to include('action="/likes"')
      expect(body).to include('class="like-card-heart" aria-label="Ver planos para curtir de volta" href="/plans"')
    end
  end

  describe "POST /likes vindo da tela de Curtidas (source=likes)" do
    let(:ana) { person("Ana Souza") }

    before { liked_by(ana) }

    it "dá match e, ao fechar o modal, volta para Curtidas" do
      sign_in me, scope: :user
      post "/likes", params: { user_id: ana.id, source: "likes" },
                     headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include('data-match-modal-dismiss-path-value="/notifications"')
      expect(Match.for_user(me.id).where(user_id: ana.id).or(Match.for_user(me.id).where(matched_user_id: ana.id))).to exist
    end

    it "se você já tinha curtido, volta para Curtidas (e não para o Início)" do
      Like.create!(liker: me, liked: ana)

      sign_in me, scope: :user
      post "/likes", params: { user_id: ana.id, source: "likes" }

      expect(response).to redirect_to("/notifications")
    end
  end
end
