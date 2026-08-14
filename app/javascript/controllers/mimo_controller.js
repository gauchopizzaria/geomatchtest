import { Controller } from "@hotwired/stimulus"
import { launchConfetti } from "../confetti_animation.js"

// Cobre as 3 telas do fluxo de envio de Mimos (Fase 4):
//   Catálogo     — busca itens em /mimo_items/catalog e o saldo em /wallet
//   Confirmação  — envia o Mimo via POST /mimo/send e redireciona ao checkout
//   Celebração   — anima o recebimento (Lottie + confetti já existente no app)
export default class extends Controller {
  static targets = [
    "grid", "balance",                                          // catálogo
    "tabUser", "tabPhone", "phoneSection", "phoneInput", "phoneError", // catálogo — convite por telefone
    "message", "error", "sendButton", "sendWalletButton",       // confirmação
    "lottieStage", "lottiePlayer", "fallback"                   // celebração
  ]

  static values = {
    receiverId: String,
    receiverPhone: String,
    itemId: String,
    catalogUrl: String,
    walletUrl: String,
    confirmUrl: String,
    sendUrl: String,
    sendWithWalletUrl: String,
    celebrationUrlBase: String
  }

  connect() {
    this.recipientMode = "user"
    if (this.hasGridTarget) this.loadCatalog()
    if (this.hasLottieStageTarget) this.setupCelebration()
  }

  // ────────────────────── DESTINATÁRIO (usuário x telefone) ──────────────────────
  showUserTab() {
    this.recipientMode = "user"
    this.tabUserTarget.classList.add("is-active")
    this.tabPhoneTarget.classList.remove("is-active")
    this.phoneSectionTarget.hidden = true
  }

  showPhoneTab() {
    this.recipientMode = "phone"
    this.tabPhoneTarget.classList.add("is-active")
    this.tabUserTarget.classList.remove("is-active")
    this.phoneSectionTarget.hidden = false
  }

  // Máscara simples de celular BR: (00) 00000-0000 (aceita fixo de 8 dígitos também).
  maskPhone(event) {
    const digits = event.target.value.replace(/\D/g, "").slice(0, 11)
    let masked = digits

    if (digits.length > 10) {
      masked = digits.replace(/(\d{2})(\d{5})(\d{0,4})/, (_, ddd, first, last) => last ? `(${ddd}) ${first}-${last}` : `(${ddd}) ${first}`)
    } else if (digits.length > 6) {
      masked = digits.replace(/(\d{2})(\d{4})(\d{0,4})/, (_, ddd, first, last) => last ? `(${ddd}) ${first}-${last}` : `(${ddd}) ${first}`)
    } else if (digits.length > 2) {
      masked = digits.replace(/(\d{2})(\d{0,4})/, (_, ddd, rest) => rest ? `(${ddd}) ${rest}` : `(${ddd}`)
    } else if (digits.length > 0) {
      masked = `(${digits}`
    }

    event.target.value = masked
  }

  // ───────────────────────── CATÁLOGO ─────────────────────────
  async loadCatalog() {
    try {
      const requests = [this.fetchJson(this.catalogUrlValue)]
      if (this.hasBalanceTarget) requests.push(this.fetchJson(this.walletUrlValue))

      const [catalog, wallet] = await Promise.all(requests)
      this.renderGrid(catalog.items || [])
      if (wallet) this.balanceTarget.textContent = wallet.balance_formatted || "R$ 0,00"
    } catch (e) {
      this.gridTarget.innerHTML = '<div class="gm-mimo-empty">Não foi possível carregar o catálogo. Tente novamente.</div>'
      console.error("[Mimo] loadCatalog falhou:", e)
    }
  }

  renderGrid(items) {
    if (!items.length) {
      this.gridTarget.innerHTML = '<div class="gm-mimo-empty">Nenhum Mimo disponível no momento.</div>'
      return
    }

    this.gridTarget.innerHTML = ""
    items.forEach((item) => {
      const card = document.createElement("a")
      card.href = "#"
      card.className = "gm-mimo-card"
      card.innerHTML = `
        <div class="gm-mimo-card-icon">${this.escapeHtml(item.icon || "🎁")}</div>
        <h4>${this.escapeHtml(item.name)}</h4>
        <span class="gm-mimo-price">${this.escapeHtml(item.price_formatted || "")}</span>
      `
      card.addEventListener("click", (event) => {
        event.preventDefault()
        this.goToConfirm(item)
      })
      this.gridTarget.appendChild(card)
    })
  }

  goToConfirm(item) {
    const params = new URLSearchParams({
      mimo_item_id: item.id,
      name: item.name,
      price_formatted: item.price_formatted || "",
      icon: item.icon || ""
    })

    if (this.recipientMode === "phone") {
      const phone = this.hasPhoneInputTarget ? this.phoneInputTarget.value.replace(/\D/g, "") : ""
      if (phone.length < 10) {
        if (this.hasPhoneErrorTarget) {
          this.phoneErrorTarget.textContent = "Informe um celular válido, com DDD."
          this.phoneErrorTarget.classList.add("is-visible")
        }
        return
      }
      params.set("phone", phone)
    } else {
      params.set("receiver_id", this.receiverIdValue)
    }

    window.location.href = `${this.confirmUrlValue}?${params.toString()}`
  }

  // ───────────────────────── CONFIRMAÇÃO / ENVIO ─────────────────────────
  async send() {
    this.setLoading(true)
    this.hideError()

    // Convite por telefone: MimoTransaction#exactly_one_recipient exige
    // exatamente um dos dois — nunca envia receiver_id junto com phone.
    const isPhoneInvite = !this.receiverIdValue && !!this.receiverPhoneValue

    try {
      const response = await fetch(this.sendUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.csrfToken()
        },
        body: JSON.stringify({
          receiver_id: isPhoneInvite ? undefined : this.receiverIdValue,
          phone: isPhoneInvite ? this.receiverPhoneValue : undefined,
          mimo_item_id: this.itemIdValue,
          message: this.hasMessageTarget ? this.messageTarget.value : undefined
        })
      })

      const data = await response.json().catch(() => ({}))

      if (!response.ok) {
        this.showError(data.error || "Não foi possível enviar o Mimo. Tente novamente.")
        this.setLoading(false)
        return
      }

      if (isPhoneInvite) {
        // O SMS de convite só é disparado quando o pagamento é aprovado (webhook
        // -> MimoPaymentService.complete!), mas o remetente já pode ser
        // tranquilizado aqui — daí o pequeno atraso antes do redirect ao checkout,
        // só para dar tempo do toast aparecer na tela.
        this.showInviteToast("Convite enviado! Assim que o pagamento for aprovado, enviaremos um SMS de convite para o destinatário resgatar o Mimo.")
        setTimeout(() => { window.location.href = data.checkout_url }, 1600)
        return
      }

      window.location.href = data.checkout_url
    } catch (e) {
      console.error("[Mimo] send falhou:", e)
      this.showError("Falha de conexão. Verifique sua internet e tente novamente.")
      this.setLoading(false)
    }
  }

  // Paga com o saldo já depositado na carteira — transferência interna e
  // síncrona (ver MimoWalletPaymentService), sem ida ao checkout do Mercado
  // Pago: em caso de sucesso já pula direto para a tela de Celebração.
  async sendWithWallet() {
    this.setWalletLoading(true)
    this.hideError()

    try {
      const response = await fetch(this.sendWithWalletUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.csrfToken()
        },
        body: JSON.stringify({
          receiver_id: this.receiverIdValue,
          mimo_item_id: this.itemIdValue,
          message: this.hasMessageTarget ? this.messageTarget.value : undefined
        })
      })

      const data = await response.json().catch(() => ({}))

      if (!response.ok) {
        this.showError(data.error || "Não foi possível pagar com o saldo da carteira.")
        this.setWalletLoading(false)
        return
      }

      window.location.href = this.celebrationUrlBaseValue.replace("PLACEHOLDER_ID", data.mimo_transaction_id)
    } catch (e) {
      console.error("[Mimo] sendWithWallet falhou:", e)
      this.showError("Falha de conexão. Verifique sua internet e tente novamente.")
      this.setWalletLoading(false)
    }
  }

  // Replica o DOM de shared/_toast.html.erb (mesmo mecanismo de toast_controller.js)
  // para dar feedback imediato de uma ação client-side, sem precisar de um
  // round-trip/redirect só para exibir a flash message.
  showInviteToast(message) {
    const container = document.getElementById("toast-container")
    if (!container) return

    const toast = document.createElement("div")
    toast.className = "toast toast--notice"
    toast.setAttribute("data-controller", "toast")
    toast.setAttribute("role", "alert")
    toast.setAttribute("aria-live", "polite")
    toast.innerHTML = `
      <span class="toast__message">${this.escapeHtml(message)}</span>
      <button class="toast__close" data-action="toast#close" aria-label="Fechar">✕</button>
    `
    container.prepend(toast)
  }

  // ───────────────────────── CELEBRAÇÃO ─────────────────────────
  setupCelebration() {
    launchConfetti()

    const player = this.lottiePlayerTarget
    const showFallback = () => {
      player.style.display = "none"
      this.fallbackTarget.style.display = "grid"
    }

    // Sem asset Lottie definido (arquivo real ainda não entregue pelo design) —
    // cai direto no emoji estático, nunca deixa a tela vazia.
    if (!player.getAttribute("src")) {
      showFallback()
      return
    }

    player.addEventListener("error", showFallback)

    // Se o <script> do CDN não carregar (offline/CDN fora do ar), o elemento
    // <lottie-player> nunca é "definido" como custom element — usa o fallback
    // depois de uma janela curta de espera.
    const timeout = setTimeout(showFallback, 2500)
    if (window.customElements?.whenDefined) {
      window.customElements.whenDefined("lottie-player").then(() => clearTimeout(timeout))
    }
  }

  // ───────────────────────── Helpers ─────────────────────────
  async fetchJson(url) {
    const response = await fetch(url, { headers: { Accept: "application/json" } })
    if (!response.ok) throw new Error(`GET ${url} -> ${response.status}`)
    return response.json()
  }

  setLoading(isLoading) {
    if (!this.hasSendButtonTarget) return
    this.sendButtonTarget.classList.toggle("is-loading", isLoading)
    this.sendButtonTarget.disabled = isLoading
  }

  setWalletLoading(isLoading) {
    if (!this.hasSendWalletButtonTarget) return
    this.sendWalletButtonTarget.classList.toggle("is-loading", isLoading)
    this.sendWalletButtonTarget.disabled = isLoading
  }

  showError(message) {
    if (!this.hasErrorTarget) return
    this.errorTarget.textContent = message
    this.errorTarget.classList.add("is-visible")
  }

  hideError() {
    if (!this.hasErrorTarget) return
    this.errorTarget.classList.remove("is-visible")
  }

  escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
