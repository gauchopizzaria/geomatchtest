# CLAUDE.md — GeoMatch

Guia operacional para o Claude Code. Leia este arquivo inteiro antes de qualquer tarefa.

---

## Vault de Documentação

**Localização:** `C:\Users\Felipe\Documents\DEV\GeoMatch\geomatchobsidion\geomatch\geomatch docs`

A documentação é a fonte de verdade do projeto. Consulte-a antes de implementar qualquer feature.

### Mapa da documentação por tipo de tarefa

| Tarefa | Arquivo no vault |
|--------|-----------------|
| Entender o sistema como um todo | `GeoMatch MOC.md` |
| Trabalhar com usuários, perfis, planos | `Modelo de Usuario.md`, `Planos e Assinaturas.md` |
| Login, sessão, JWT, banimento | `Autenticacao e Sessoes.md` |
| Discovery, swipe, mapa 3D | `Sistema de Descoberta.md` |
| Curtidas, matches | `Sistema de Match.md` |
| Chat, ActionCable, reações | `Sistema de Mensagens.md` |
| Pagamentos, Mercado Pago, state machine | `Sistema de Pagamentos.md` |
| Webhooks de pagamento | `Webhooks Mercado Pago.md` |
| Push notifications, ActionCable in-app | `Sistema de Notificacoes.md` |
| Geolocalização, Geocoder, raio | `Sistema de Localizacao.md` |
| Stories, posts com mídia | `Sistema de Stories.md` |
| Bloqueio, denúncia, banimento | `Sistema de Seguranca.md` |
| Painel admin, stats, moderação | `Painel Administrativo.md` |
| API REST mobile/admin, JWT | `API REST.md` |
| Background jobs, Solid Queue | `Sistema de Filas.md` |
| Stimulus, Leaflet, Turbo, PWA | `Frontend e JavaScript.md` |
| ENV, gems, deploy Kamal | `Configuracao e Infraestrutura.md` |

---

## Protocolo Obrigatório

### Antes de qualquer alteração
1. Leia o arquivo de documentação correspondente no vault
2. Leia os arquivos de código relevantes (não assuma — leia)
3. Identifique todos os pontos de integração listados no vault

### Depois de qualquer alteração
1. Verifique se o comportamento alterado está documentado no vault
2. Se sim: atualize o arquivo `.md` correspondente
3. Se criou algo novo: crie um arquivo `.md` novo no vault com o frontmatter padrão
4. Atualize o `GeoMatch MOC.md` se adicionou um novo módulo

### Frontmatter padrão para novos arquivos no vault
```markdown
---
tags: [tags-relevantes]
relacionado: [[Arquivos conectados]]
status: ativo
tipo: feature | arquitetura | decisão | endpoint | componente
versao: 1.0.0
---
```

---

## Arquitetura Geral

```
GeoMatch — Rails 8.1 / PostgreSQL / Hotwire
├── Web App
│   ├── Devise (autenticação por sessão/cookie)
│   ├── Turbo + Stimulus (frontend reativo sem SPA)
│   └── ActionCable via Solid Cable (WebSocket no PostgreSQL)
├── API REST (/api/v1/)
│   ├── JWT (30 dias, HS256)
│   ├── Mobile (Android) — matches, messages, location
│   └── Admin — stats, users, moderation (requer admin: true)
├── Pagamentos
│   ├── Mercado Pago Checkout Pro
│   ├── AASM state machine (created → pending → approved/rejected → refunded)
│   └── Webhook assíncrono → WebhookEvent → PaymentStateMachine
├── Background
│   ├── Solid Queue (jobs em PostgreSQL)
│   └── Sidekiq Cron (ExpireSubscriptionsJob agendado)
└── Storage
    ├── Cloudinary + Active Storage (avatares, fotos, stories)
    └── PostgreSQL (dados + filas + WebSocket + cache)
```

### Fluxo crítico: curtida → match → mensagem
```
POST /likes
→ can_like? (plano Free: 47/5h | Plus/Gold: ilimitado)
→ Like.create + increment_likes!
→ Like recíproco? → Match.create
→ Notificação criada → NotificationBroadcastJob → ActionCable

POST /matches/:id/messages
→ can_send_message? (Free: 3/24h ou crédito avulso | Plus/Gold: ilimitado)
→ Message.create → after_create_commit
  → broadcast_message → MatchChannel (ActionCable)
  → send_push_notification → Web Push (offline)
```

### Fluxo crítico: pagamento
```
POST /checkout → MercadoPago::CheckoutProService
→ Payment (state: created) + preference no MP
→ Usuário paga → POST /webhooks/mercado_pago
→ WebhookEvent (status: pending) → WebhookService
→ payment.approve → PaymentStateMachine
→ user.plan atualizado + premium_until setado
```

---

## Comandos Essenciais

```bash
# Desenvolvimento (inicia web + CSS watch + JS watch)
bin/dev

# Processos individualmente
bin/rails server -p 3000      # Servidor web
bin/rails dartsass:watch      # CSS (SCSS)
yarn build --watch            # JavaScript (ESBuild)
bin/jobs                      # Solid Queue worker

# Banco de dados
bin/rails db:create db:migrate
bin/rails db:seed              # 50 usuários de teste em Itabuna/BA
bin/rails db:reset             # Drop + create + migrate + seed

# Testes (RSpec — preferencial)
bundle exec rspec
bundle exec rspec spec/models/user_spec.rb
bundle exec rspec spec/requests/
bundle exec rspec spec/services/mercado_pago/

# Testes (Minitest — legado, em test/)
bin/rails test

# Console
bin/rails console

# Rotas
bin/rails routes
bin/rails routes | grep api

# Assets
yarn build                    # Build JS uma vez
bin/rails assets:precompile   # Build completo para produção

# Qualidade de código
bin/rubocop                   # Linter Ruby
bin/brakeman                  # Análise de segurança
bin/bundler-audit             # Auditoria de gems

# Deploy
bin/kamal deploy
bin/kamal rollback
```

---

## Regras Críticas

### Segurança e autenticação
- **Nunca** expor endpoint sem `authenticate_user!` (web) ou `authenticate_api_user!` (API)
- Controllers da API **sempre** herdam de `API::V1::BaseController`
- Controllers admin **sempre** herdam de `API::V1::Admin::BaseController`
- `API::LocationsController` é exceção intencional: sem JWT (legacy Android)
- Usuários banidos são bloqueados em dois pontos: `active_for_authentication?` (Devise) e verificação no JWT handler — **não remover nenhum dos dois**

### Limites de plano (não alterar sem revisão de negócio)
- Free: 47 curtidas/5h, 3 mensagens/24h
- Plus/Gold: ilimitado
- Lógica está em `User#can_like?` e `User#can_send_message?` em `app/models/user.rb`
- Crédito avulso: R$ 1,99 → `one_off_message_credits` no User

### Descoberta e privacidade
- **Sempre** aplicar `User.visible` scope antes de qualquer query de discovery
- **Sempre** excluir `current_user.excluded_user_ids` (bloqueados + quem bloqueou)
- Usuários com `invisible: true`: não atualizar localização, não exibir em busca
- Plano Free é obrigatório como padrão — `Plan.find_by(code: 'free')` deve existir

### Pagamentos (AASM)
- Nunca chamar `payment.state =` diretamente — usar apenas os eventos AASM (`approve`, `reject`, `refund`)
- `admin_grant` cria Payment real no banco mesmo sem cobrança — não contornar isso
- UUIDs como PK em `payments` e `webhook_events` — manter em novas migrations

### ActionCable
- Backend: Solid Cable (PostgreSQL) — não adicionar Redis só para isso
- `MatchChannel` valida participação antes de subscrever — não enfraquecer essa verificação
- Broadcasts em `after_create_commit` são síncronos — considerar isso ao adicionar lógica pesada

### Bloqueios
- Bloquear destrói matches e likes existentes automaticamente (`UsersController#block`)
- `excluded_user_ids` é bidirecional — A bloqueia B = B também não vê A

### Migrações
- Habilitar `pgcrypto` já foi feito (`20260127000000_enable_pgcrypto.rb`)
- UUIDs em payments e webhook_events — padrão para novas tabelas financeiras
- Geocoder popula cidade/estado/país via `before_validation` — não remover callback

---

## Estrutura de Arquivos Chave

```
app/
├── models/
│   ├── user.rb                    # Entidade central — ler antes de tocar
│   ├── payment.rb                 # + concerns/payment_state_machine.rb
│   ├── match.rb, message.rb       # Core do chat
│   └── concerns/payment_state_machine.rb
├── controllers/
│   ├── application_controller.rb  # before_actions globais
│   ├── api/v1/base_controller.rb  # JWT auth base
│   ├── api/v1/admin/base_controller.rb
│   └── webhooks/mercado_pago_controller.rb
├── services/
│   ├── discovery_service.rb
│   ├── advanced_discovery_service.rb
│   ├── jwt_service.rb
│   └── mercado_pago/
│       ├── checkout_pro_service.rb
│       ├── one_off_message_service.rb
│       ├── checkout_preference_builder.rb
│       └── webhook_service.rb
├── jobs/
│   ├── expire_subscriptions_job.rb   # Agendado via Sidekiq Cron
│   └── notification_broadcast_job.rb
├── channels/
│   ├── match_channel.rb
│   └── notification_channel.rb
└── javascript/
    ├── map_3d.js, live_location.js
    ├── chat_logic.js, chat_list_logic.js
    ├── push_notifications.js
    └── controllers/ (Stimulus)

config/
├── routes.rb          # Organizado em 8 seções numeradas
├── initializers/
│   ├── cors.rb        # CORS por namespace de rota
│   ├── geocoder.rb    # Nominatim, km, HTTPS, User-Agent
│   ├── money.rb       # Moeda padrão: BRL
│   └── sidekiq_cron.rb

spec/                  # RSpec (preferencial)
test/                  # Minitest (legado — não adicionar novos testes aqui)
```

---

## Variáveis de Ambiente Necessárias

```bash
DATABASE_USERNAME / DATABASE_PASSWORD
REDIS_URL
CLOUDINARY_URL  # ou CLOUDINARY_CLOUD_NAME + API_KEY + API_SECRET
MERCADO_PAGO_ACCESS_TOKEN
MERCADO_PAGO_PUBLIC_KEY
VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY
SMTP_USERNAME / SMTP_PASSWORD
MAPBOX_TOKEN
APP_BASE_URL  # Usado nas back_urls do MP e nos webhooks
APNS_KEY_P8   # Conteúdo da chave .p8 da Apple (com \n escapado — desescapado em runtime via StringIO)
APNS_KEY_ID   # 10 caracteres, identificador da chave .p8 no Apple Developer Portal
APNS_TEAM_ID  # 10 caracteres, identificador do time Apple Developer
APNS_ENV      # "production" (default) ou "development" — seleciona endpoint do APNs
APNS_TOPIC    # Bundle ID do app iOS (default: br.com.geomatch.app)
FCM_PROJECT_ID # Firebase Cloud Messaging (push Android) — usa firebase-credentials.json na raiz

# Mimos (presentes virtuais — ver app/services/mimo_*.rb, mp_transfer_service.rb, withdrawal_service.rb)
MERCADO_PAGO_OPERATIONAL_ACCOUNT_ID  # Conta MP "operacional" (recebe checkouts) — MpTransferService
MERCADO_PAGO_POOL_ACCOUNT_ID         # Conta MP "bolsão" (lastreia saldo sacável dos usuários) — MpTransferService
SMS_PROVIDER_URL                     # Endpoint HTTP do provedor de SMS — MimoInviteService
SMS_PROVIDER_API_KEY                 # Bearer token do provedor de SMS — MimoInviteService
# Todas ausentes por padrão: as features acima degradam graciosamente (logam e
# pulam) em vez de quebrar o fluxo principal, seguindo o padrão de PushNotificationJob.
```

---

## Lacunas de Documentação Identificadas

Itens presentes no código mas **sem documentação no vault**:

1. **`app/services/message_analyzer.rb`** e **`sentiment_analyzer.rb`** — existem mas não foram documentados
2. **`app/controllers/discover_controller.rb`** — controller separado de `users_controller.rb` para discover, não documentado
3. **`config/initializers/sidekiq_cron.rb`** — existe mas o schedule exato do `ExpireSubscriptionsJob` não está documentado
4. **`db/seeds.rb`** — seed incompleto: não cria Plans, Payments ou usuário admin. Novo usuário sem plano Free no banco quebrará o callback `set_default_plan`
5. **`spec/` vs `test/`** — projeto tem dois frameworks de teste (RSpec e Minitest legado). Não há guideline documentado de qual usar
6. **Pundit policies** — `app/policies/application_policy.rb` existe mas não há policies específicas documentadas
7. **`app/controllers/api/v1/admin/`** — vários controllers mencionados nas rotas (`live_map`, `analytics`, `heatmap`, etc.) sem documentação de implementação
8. **`bin/ci`** — script CI existe mas usa `ruby.exe` (Windows-specific) — pode falhar em CI Linux

---

## Active Context

> Atualize esta seção manualmente a cada sessão com o que está sendo trabalhado.

```
Última atualização: 2026-04-12
Sessão atual: Geração de documentação inicial no vault + CLAUDE.md
Branch: main
Status: Documentação criada. Código não foi alterado.
Próximos passos: —
```
