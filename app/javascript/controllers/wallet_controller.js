import { Controller } from "@hotwired/stimulus"

// Cobre as 3 telas da carteira (Fase 4 + Fase 5.2):
//   Carteira  — saldo (/wallet) + extrato (/wallet/transactions)
//   Saque     — envia POST /wallet/withdraw com valor + chave Pix
//   Depósito  — envia POST /wallet/deposit e redireciona ao checkout do Mercado Pago
export default class extends Controller {
  static targets = [
    "balance", "history",                                                             // carteira
    "amountInput", "availableText", "keyOptions", "keyInput", "error", "withdrawButton", // saque
    "depositAmountInput", "depositError", "depositButton"                              // depósito
  ]

  static values = {
    showUrl: String,
    transactionsUrl: String,
    withdrawUrl: String,
    withdrawPageUrl: String,
    walletPageUrl: String,
    depositUrl: String
  }

  selectedKeyType = null

  connect() {
    if (this.hasBalanceTarget || this.hasAmountInputTarget) this.loadWallet()
    if (this.hasHistoryTarget) this.loadTransactions()
  }

  // ───────────────────────── CARTEIRA ─────────────────────────
  async loadWallet() {
    try {
      const wallet = await this.fetchJson(this.showUrlValue)

      if (this.hasBalanceTarget) this.balanceTarget.textContent = wallet.balance_formatted || "R$ 0,00"

      if (this.hasAvailableTextTarget) {
        this.availableTextTarget.textContent = this.formatCents(wallet.available_balance_cents || 0)
      }
      if (this.hasAmountInputTarget && wallet.available_balance_cents > 0) {
        this.amountInputTarget.value = this.formatCents(wallet.available_balance_cents)
      }
      if (this.hasKeyInputTarget && wallet.pix_key) {
        this.keyInputTarget.value = wallet.pix_key
        if (wallet.pix_key_type) this.applyKeyType(wallet.pix_key_type)
      }
    } catch (e) {
      console.error("[Wallet] loadWallet falhou:", e)
    }
  }

  async loadTransactions() {
    try {
      const data = await this.fetchJson(this.transactionsUrlValue)
      this.renderHistory(data.transactions || [])
    } catch (e) {
      this.historyTarget.innerHTML = '<p class="gm-wallet-empty-hist">Não foi possível carregar o extrato.</p>'
      console.error("[Wallet] loadTransactions falhou:", e)
    }
  }

  renderHistory(entries) {
    if (!entries.length) {
      this.historyTarget.innerHTML = '<p class="gm-wallet-empty-hist">Nenhuma movimentação ainda.</p>'
      return
    }

    this.historyTarget.innerHTML = entries.map((entry) => {
      const isIn = entry.amount_cents >= 0
      const arrow = isIn
        ? '<path d="M12 19V5M5 12l7-7 7 7"/>'
        : '<path d="M12 5v14M5 12l7 7 7-7"/>'

      return `
        <div class="gm-wallet-hist-item">
          <div class="gm-wallet-hist-ic ${isIn ? "in" : "out"}">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">${arrow}</svg>
          </div>
          <div class="gm-wallet-hist-mid">
            <strong>${this.escapeHtml(entry.description)}</strong>
            <small>${this.formatDate(entry.created_at)}</small>
          </div>
          <span class="gm-wallet-hist-val ${isIn ? "in" : "out"}">${isIn ? "+" : "-"} ${this.formatCents(Math.abs(entry.amount_cents))}</span>
        </div>
      `
    }).join("")
  }

  goToWithdraw() {
    if (this.hasWithdrawPageUrlValue) window.location.href = this.withdrawPageUrlValue
  }

  // ───────────────────────── SAQUE ─────────────────────────
  selectKeyType(event) {
    this.applyKeyType(event.currentTarget.dataset.keyType)
  }

  applyKeyType(keyType) {
    this.selectedKeyType = keyType
    this.keyOptionsTarget.querySelectorAll(".gm-saque-key-opt").forEach((opt) => {
      opt.classList.toggle("is-selected", opt.dataset.keyType === keyType)
    })
  }

  async withdraw() {
    this.hideError()

    const amountCents = this.parseAmountToCents(this.amountInputTarget.value)
    if (!amountCents || amountCents <= 0) {
      this.showError("Informe um valor válido para o saque.")
      return
    }

    const pixKey = this.hasKeyInputTarget ? this.keyInputTarget.value.trim() : ""
    if (!pixKey || !this.selectedKeyType) {
      this.showError("Selecione o tipo de chave e informe a chave Pix.")
      return
    }

    this.setLoading(true)

    try {
      const response = await fetch(this.withdrawUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.csrfToken()
        },
        body: JSON.stringify({ amount_cents: amountCents, pix_key: pixKey, pix_key_type: this.selectedKeyType })
      })

      const data = await response.json().catch(() => ({}))

      if (!response.ok) {
        this.showError(data.error || "Não foi possível processar o saque.")
        this.setLoading(false)
        return
      }

      window.location.href = this.hasWalletPageUrlValue ? this.walletPageUrlValue : "/carteira"
    } catch (e) {
      console.error("[Wallet] withdraw falhou:", e)
      this.showError("Falha de conexão. Verifique sua internet e tente novamente.")
      this.setLoading(false)
    }
  }

  // ───────────────────────── DEPÓSITO ─────────────────────────
  selectDepositPreset(event) {
    const cents = parseInt(event.currentTarget.dataset.amountCents, 10)
    if (this.hasDepositAmountInputTarget) this.depositAmountInputTarget.value = this.formatCents(cents)

    this.element.querySelectorAll(".gm-deposit-preset").forEach((btn) => {
      btn.classList.toggle("is-selected", parseInt(btn.dataset.amountCents, 10) === cents)
    })
    this.hideDepositError()
  }

  // Digitar um valor manualmente desmarca qualquer preset selecionado — o
  // input de texto é sempre a fonte de verdade do valor a depositar.
  clearDepositPreset() {
    this.element.querySelectorAll(".gm-deposit-preset").forEach((btn) => btn.classList.remove("is-selected"))
  }

  async deposit() {
    this.hideDepositError()

    const amountCents = this.hasDepositAmountInputTarget ? this.parseAmountToCents(this.depositAmountInputTarget.value) : 0
    if (!amountCents || amountCents < 500) {
      this.showDepositError("Informe um valor de pelo menos R$ 5,00.")
      return
    }

    this.setDepositLoading(true)

    try {
      const response = await fetch(this.depositUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.csrfToken()
        },
        body: JSON.stringify({ amount_cents: amountCents })
      })

      const data = await response.json().catch(() => ({}))

      if (!response.ok) {
        this.showDepositError(data.error || "Não foi possível iniciar o depósito.")
        this.setDepositLoading(false)
        return
      }

      window.location.href = data.checkout_url
    } catch (e) {
      console.error("[Wallet] deposit falhou:", e)
      this.showDepositError("Falha de conexão. Verifique sua internet e tente novamente.")
      this.setDepositLoading(false)
    }
  }

  setDepositLoading(isLoading) {
    if (!this.hasDepositButtonTarget) return
    this.depositButtonTarget.classList.toggle("is-loading", isLoading)
    this.depositButtonTarget.disabled = isLoading
  }

  showDepositError(message) {
    if (!this.hasDepositErrorTarget) return
    this.depositErrorTarget.textContent = message
    this.depositErrorTarget.classList.add("is-visible")
  }

  hideDepositError() {
    if (!this.hasDepositErrorTarget) return
    this.depositErrorTarget.classList.remove("is-visible")
  }

  // ───────────────────────── Helpers ─────────────────────────
  async fetchJson(url) {
    const response = await fetch(url, { headers: { Accept: "application/json" } })
    if (!response.ok) throw new Error(`GET ${url} -> ${response.status}`)
    return response.json()
  }

  setLoading(isLoading) {
    if (!this.hasWithdrawButtonTarget) return
    this.withdrawButtonTarget.classList.toggle("is-loading", isLoading)
    this.withdrawButtonTarget.disabled = isLoading
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

  formatCents(cents) {
    return (cents / 100).toLocaleString("pt-BR", { style: "currency", currency: "BRL" })
  }

  // Aceita "R$ 120,00", "120,00", "120.00" ou "120"
  parseAmountToCents(rawValue) {
    const cleaned = (rawValue || "").replace(/[^\d,.-]/g, "")
    const normalized = cleaned.includes(",")
      ? cleaned.replace(/\./g, "").replace(",", ".")
      : cleaned
    const amount = parseFloat(normalized)
    return Number.isNaN(amount) ? 0 : Math.round(amount * 100)
  }

  formatDate(iso) {
    const date = new Date(iso)
    if (Number.isNaN(date.getTime())) return ""
    const day = date.toLocaleDateString("pt-BR", { day: "2-digit", month: "2-digit" })
    const time = date.toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" })
    return `${day}, ${time}`
  }

  escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str || ""
    return div.innerHTML
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
