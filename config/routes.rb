Rails.application.routes.draw do
  # =================================================================
  # 1. AUTENTICAÇÃO (DEVISE)
  # =================================================================
  devise_for :users, controllers: {
    omniauth_callbacks: "users/omniauth_callbacks",
    registrations:      "users/registrations",
    sessions:           "users/sessions"
  }

  devise_scope :user do
    delete "/logout", to: "users/sessions#destroy", as: :logout
  end

  # =================================================================
  # 2. ROTAS PÚBLICAS E GERAIS
  # =================================================================
  root "pages#landing"

  # --- NOVAS ROTAS (Termos e Privacidade para o Cadastro) ---
  # Estas rotas apontam para o PagesController criado para o formulário
  get 'termos-de-uso', to: 'pages#terms', as: 'terms'
  get 'politica-de-privacidade', to: 'pages#privacy', as: 'privacy'
  get '/suporte', to: 'pages#suporte', as: 'suporte'
  get '/instalar', to: 'pages#testflight_guide', as: 'testflight_guide'

  # Exclusão de Conta e Dados — página pública exigida pela Google Play Store
  get  '/exclusao-de-conta', to: 'account_deletions#new',    as: :account_deletion
  post '/exclusao-de-conta', to: 'account_deletions#create'
  # -----------------------------------------------------------

  # Path configuration para Hotwire Native iOS
  get "/configurations/native.json", to: "path_configurations#show", as: :native_path_configuration

  # Sitemap dinâmico com posts
  get "/sitemap.xml", to: "sitemaps#index", format: :xml

  # Páginas estáticas existentes (Mantidas)
  get "/terms",    to: "public#terms",   as: :terms_of_use
  get "/privacy",  to: "public#privacy", as: :privacy_policy
  get "/profiles", to: "public#profiles", as: :public_profiles
  get "notifications/index"

  # Blog
  get "/blog", to: "blog_posts#index", as: "blog"
  get "/blog/categoria/:category", to: "blog_posts#index", as: "blog_category"
  get "/blog/:slug", to: "blog_posts#show", as: "blog_post"

  # Stories
  resources :stories, only: [:index, :create]

  # Likes, Favoritos e Notificações
  resources :likes,     only: [:create, :destroy]
  resources :favorites, only: [:index, :create, :destroy]
  resources :notifications, only: [:index]

  # =================================================================
  # 3. FUNCIONALIDADES DE DISCOVERY / LEAD
  # =================================================================

  get "/discover_3d",         to: "users#discover_3d",     as: :discover_3d
  get "/discover_3d/gallery", to: "discover_3d#gallery",    as: :discover_3d_gallery


  # Lead/Swipe
  get  "/lead",        to: "users#lead",   as: :lead
  post "/lead",        to: "users#lead"
  post "/lead/reject", to: "users#reject", as: :reject_user
  post "/lead/rewind", to: "users#rewind", as: :rewind_lead

  # Iniciar chat direto
  post 'start_chat/:user_id', to: 'matches#start_chat', as: :start_chat

  # =================================================================
  # 4. MATCHES E MENSAGENS (CONSOLIDADO)
  # =================================================================
  # Aqui juntamos a exibição, as mensagens e a ação de limpar conversa
  resources :matches, only: [:index, :show] do
    # Rotas aninhadas (mensagens dentro do match)
    resources :messages, only: [:index, :create, :destroy] do
      member do
        post :react
      end
    end
    
    # Ações de membro (agem sobre um match específico)
    member do
      delete :clear_conversation
    end
  end

  # =================================================================
  # 5. USUÁRIOS (CONSOLIDADO)
  # =================================================================
  
  # IMPORTANTE: Rotas específicas de /users/ devem vir ANTES de resources :users
  # para não confundir "nearby" com um ID de usuário (ex: users/1)
  get "/users/nearby", to: "users#nearby"

  resources :users, only: [:show, :update] do
    # Ações de membro (agem sobre um ID específico: /users/:id/block)
    member do
      post   :block
      delete :unblock
    end

    # Ações de coleção (agem sobre a lista ou contexto geral: /users/update_location)
    collection do
      post :update_location
      post :toggle_visibility
    end
  end

  # Funcionalidades extras de usuário
  get "/safety_center",         to: "users#safety_center",   as: :safety_center
  get "/safety_center/history", to: "users#safety_history",  as: :safety_history
  get "/report_incident",       to: "users#report_incident", as: :report_incident
  get "/meu-perfil",      to: "users#me_profile",      as: :my_profile
  get  "/onboarding",    to: "users#onboarding",          as: :onboarding
  patch "/onboarding",   to: "users#complete_onboarding"
  get '/verificacao', to: 'users#verification', as: :verification
  patch '/verificacao', to: 'users#send_verification', as: :send_verification
  post "/apply_coupon", to: "users#apply_coupon", as: :apply_coupon

  # Edição do próprio perfil
  resource :profile, controller: 'users', only: [:edit, :update] do
    get  "preview",      on: :collection
    post "upload_avatar", on: :collection
    get  "crop_avatar",  on: :collection
    post "apply_crop",   on: :collection
  end

  # Fotos do álbum
  delete 'album_photos/:id', to: 'album_photos#destroy', as: :delete_album_photo

  # =================================================================
  # 6. PAGAMENTOS (CHECKOUT)
  # =================================================================
  
  # --- ALTERAÇÃO AQUI: Adicionada a rota para o Modal ---
  resources :plans, only: [:index] do
    collection do
      get :modal
    end
  end
  # ------------------------------------------------------

  post "/checkout",                    to: "checkout#create",                  as: :checkout
  post "/checkout/one_off_message",    to: "checkout#create_one_off_message",  as: :new_one_off_message_payment
  post "/webhooks/mercado_pago", to: "webhooks/mercado_pago#create", as: :mercado_pago_webhook

  # =================================================================
  # 6b. MIMOS (presentes virtuais) E CARTEIRA
  # =================================================================
  get  "/mimo_items/catalog", to: "mimos#catalog", as: :mimo_items_catalog
  # action `create` (não `send`): nomear uma action `send` sombrearia Kernel#send
  # na instância do controller — mesmo cuidado já aplicado aos eventos AASM na Fase 2.
  post "/mimo/send",          to: "mimos#create",           as: :send_mimo
  post "/mimo/send_with_wallet", to: "mimos#send_with_wallet", as: :send_mimo_with_wallet

  get   "/wallet",                to: "wallets#show",           as: :wallet
  post  "/wallet/withdraw",       to: "wallets#withdraw",       as: :withdraw_wallet
  post  "/wallet/deposit",        to: "wallets#deposit",        as: :deposit_wallet
  # Conciliação sob demanda: usada no retorno do checkout do MP, quando a
  # notificação de webhook pode ainda não ter chegado (ou ter se perdido).
  post  "/wallet/reconcile",      to: "wallets#reconcile",      as: :reconcile_wallet
  patch "/wallet/update_pix_key", to: "wallets#update_pix_key", as: :update_wallet_pix_key
  get   "/wallet/transactions",   to: "wallets#transactions",   as: :wallet_transactions

  # --- Views HTML do fluxo de Mimos (consomem os endpoints JSON acima via fetch) ---
  get "/mimos/catalogo",     to: "pages#mimo_catalog",     as: :mimo_catalog_page
  get "/mimos/confirmar",    to: "pages#mimo_confirm",     as: :mimo_confirm_page
  get "/mimos/recebido/:id", to: "pages#mimo_celebration", as: :mimo_celebration_page
  get "/mimos/depositar",    to: "pages#mimo_deposit",     as: :mimo_deposit_page
  get "/carteira",           to: "pages#mimo_wallet",      as: :mimo_wallet_page
  get "/carteira/sacar",     to: "pages#mimo_withdraw",    as: :mimo_withdraw_page

  # =================================================================
  # 7. SISTEMA
  # =================================================================
  mount ActionCable.server => '/cable'
  get "up" => "rails/health#show", as: :rails_health_check

  # --- ADICIONE ESTAS DUAS LINHAS ABAIXO ---
  get "/service-worker.js" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "/manifest.json" => "rails/pwa#manifest", as: :pwa_manifest
  # ----------------------------------------

  # =================================================================
  # 8. PAINEL ADMIN WEB (Devise auth + admin? check)
  # =================================================================
  namespace :admin do
    root to: 'settings#index'
    resources :settings, only: [:index, :edit, :update]
    resources :blog_posts, only: [:index, :new, :create, :edit, :update, :destroy]
    resources :coupons
  end

  # =================================================================
  # 9. PUSH SUBSCRIPTIONS
  # =================================================================
  resources :push_subscriptions, only: [:create, :destroy] do
    collection do
      post :apns, action: :create_apns
      post :fcm, action: :create_fcm
    end
  end

  resources :reports, only: [:create]

  # Rota exclusiva para receber a localização do app nativo Android
  namespace :api do
    post 'atualizar_localizacao', to: 'locations#update'

    # =============================================================
    # API REST v1 — Autenticação JWT
    # =============================================================
    namespace :v1 do
      post   :login,    to: 'auth#login'
      get    :matches,  to: 'matches#index'
      get    :messages, to: 'messages#index'

      # -------------------------------------------------------
      # Admin Dashboard — requer admin: true + JWT válido
      # -------------------------------------------------------
      namespace :admin do
        get :stats,       to: 'stats#show'
        get :live_map,    to: 'live_map#index'
        get :analytics,   to: 'analytics#show'
        get :heatmap,     to: 'heatmap#index'
        get :performance, to: 'performance#show'
        get :word_cloud,  to: 'word_cloud#index'
        get :insights,    to: 'insights#show'
        get :bi_export,   to: 'bi_export#show'
        get :engagement,             to: 'engagement#show'
        get :political_intelligence, to: 'political_intelligence#show'

        resources :users, only: [:index] do
          member do
            patch :ban
            patch :update_subscription
          end
        end

        resources :logs, only: [:index]

        resources :reports, only: [:index] do
          member do
            patch :resolve
          end
        end

        # Gestão de Planos SaaS
        resources :plans, except: [:new, :edit]

        # Configurações dinâmicas (preços avulsos, etc.)
        resources :settings, only: [:index, :update]

        # Moderação de Fotos e Verificação de Identidade
        resources :moderation, only: [:index] do
          member do
            patch :verify_user
            patch :reject_photo
            patch :undo_rejection
            patch :ban_user
            post  :reanalyze
          end
        end
      end

      patch 'profile/survey', to: 'profiles#update_survey'
    end
  end
  
end