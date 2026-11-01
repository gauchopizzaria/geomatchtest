// app/javascript/chat_list_logic.js
// Swipe-to-action na lista de conversas (sem biblioteca externa)

const SWIPE_THRESHOLD = 48;
const ACTIONS_WIDTH   = 148;

// ── Tap seguro para mobile ───────────────────────────────────────────────────
// Evita que o touchend do swipe "roube" o clique do botão.
// Registra touchstart/touchmove para detectar se houve movimento antes do touchend.
function onTap(el, handler) {
  let moved = false;
  el.addEventListener('touchstart', () => { moved = false; }, { passive: true });
  el.addEventListener('touchmove', () => { moved = true;  }, { passive: true });
  el.addEventListener('touchend', (e) => {
    if (!moved) { e.preventDefault(); handler(e); }
  });
  el.addEventListener('click', handler); // mouse / desktop
}

// ── Swipe ────────────────────────────────────────────────────────────────────
function initSwipe(container) {
  const content = container.querySelector('.swipe-content');
  if (!content) return;

  let startX = 0, startY = 0, currentX = 0;
  let isSwiped = false, isHorizontal = null;

  // is-dragging deixa os botões visíveis (a linha é transparente sobre o fundo);
  // ao fechar, só sai depois que a animação de volta termina.
  const snapOpen  = () => { content.style.transform = `translateX(-${ACTIONS_WIDTH}px)`; isSwiped = true;  content.classList.add('is-swiped'); container.classList.add('is-dragging'); };
  const snapClose = () => {
    content.style.transform = ''; isSwiped = false; content.classList.remove('is-swiped');
    setTimeout(() => { if (!content.classList.contains('is-swiped')) container.classList.remove('is-dragging'); }, 240);
  };

  container.snapClose = snapClose; // expõe para o modal poder fechar

  content.addEventListener('touchstart', (e) => {
    startX = e.touches[0].clientX;
    startY = e.touches[0].clientY;
    currentX = isSwiped ? -ACTIONS_WIDTH : 0;
    isHorizontal = null;
    content.style.transition = 'none';
  }, { passive: true });

  content.addEventListener('touchmove', (e) => {
    const dx = e.touches[0].clientX - startX;
    const dy = e.touches[0].clientY - startY;
    if (isHorizontal === null && (Math.abs(dx) > 4 || Math.abs(dy) > 4)) {
      isHorizontal = Math.abs(dx) > Math.abs(dy);
    }
    if (!isHorizontal) return;
    e.preventDefault();
    container.classList.add('is-dragging');
    const next = Math.min(0, Math.max(-ACTIONS_WIDTH, currentX + dx));
    content.style.transform = `translateX(${next}px)`;
  }, { passive: false });

  content.addEventListener('touchend', (e) => {
    content.style.transition = '';
    const dx = e.changedTouches[0].clientX - startX;
    if (isSwiped) {
      dx > SWIPE_THRESHOLD ? snapClose() : snapOpen();
    } else {
      dx < -SWIPE_THRESHOLD ? snapOpen() : snapClose();
    }
  });
}

function closeAllSwipes(except = null) {
  document.querySelectorAll('.swipe-content.is-swiped').forEach(el => {
    const c = el.closest('.swipe-container');
    if (c !== except) { el.style.transform = ''; el.classList.remove('is-swiped'); c?.classList.remove('is-dragging'); }
  });
}

// ── CSRF ─────────────────────────────────────────────────────────────────────
function csrfToken() {
  return document.querySelector("meta[name='csrf-token']").content;
}

// ── Animação de remoção de linha ─────────────────────────────────────────────
function collapseAndRemove(el) {
  el.style.transition = 'opacity 0.22s, max-height 0.3s 0.18s, margin 0.3s 0.18s';
  el.style.overflow  = 'hidden';
  el.style.maxHeight = el.offsetHeight + 'px';
  el.style.opacity   = '0';
  requestAnimationFrame(() => { el.style.maxHeight = '0'; el.style.marginBottom = '0'; });
  setTimeout(() => el.remove(), 520);
}

// ── Modal de Bloquear / Denunciar ─────────────────────────────────────────────
function openBlockModal(container, otherUserId) {
  // Fecha o swipe antes de abrir o modal
  if (container.snapClose) container.snapClose();

  const existing = document.getElementById('swipe-block-modal');
  if (existing) existing.remove();

  const modal = document.createElement('div');
  modal.id = 'swipe-block-modal';
  modal.innerHTML = `
    <div class="sbm-backdrop"></div>
    <div class="sbm-sheet">
      <p class="sbm-title">O que deseja fazer?</p>

      <button class="sbm-btn sbm-btn-block-only" type="button">
        Apenas Bloquear
      </button>

      <button class="sbm-btn sbm-btn-report" type="button">
        Bloquear e Denunciar
      </button>

      <div class="sbm-report-area" style="display:none;">
        <textarea class="sbm-textarea" placeholder="Descreva o motivo da denúncia..." rows="3"></textarea>
        <button class="sbm-btn sbm-btn-send-report" type="button">
          Enviar Denúncia e Bloquear
        </button>
      </div>

      <button class="sbm-btn sbm-btn-cancel" type="button">Cancelar</button>
    </div>
  `;
  document.body.appendChild(modal);

  const close = () => modal.remove();

  // Fechar ao clicar no backdrop
  modal.querySelector('.sbm-backdrop').addEventListener('click', close);
  modal.querySelector('.sbm-btn-cancel').addEventListener('click', close);

  // ── Só bloquear ──────────────────────────────────────────
  onTap(modal.querySelector('.sbm-btn-block-only'), () => {
    doBlock(otherUserId, container, modal);
  });

  // ── Revelar área de denúncia ─────────────────────────────
  onTap(modal.querySelector('.sbm-btn-report'), () => {
    modal.querySelector('.sbm-report-area').style.display = 'flex';
    modal.querySelector('.sbm-btn-report').style.display  = 'none';
    modal.querySelector('.sbm-textarea').focus();
  });

  // ── Enviar denúncia e bloquear ───────────────────────────
  onTap(modal.querySelector('.sbm-btn-send-report'), () => {
    const description = modal.querySelector('.sbm-textarea').value.trim();
    if (!description) { modal.querySelector('.sbm-textarea').focus(); return; }

    // Inclui o ID do denunciado na descrição (modelo Report não tem campo próprio)
    const fullDescription = `[Usuário #${otherUserId}] ${description}`;

    fetch('/reports', {
      method: 'POST',
      headers: {
        'X-CSRF-Token': csrfToken(),
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      },
      body: JSON.stringify({ report: { description: fullDescription } })
    })
    .then(() => doBlock(otherUserId, container, modal))
    .catch(console.error);
  });
}

function doBlock(otherUserId, container, modal) {
  fetch(`/users/${otherUserId}/block`, {
    method: 'POST',
    headers: { 'X-CSRF-Token': csrfToken(), 'Accept': 'application/json' }
  }).then(r => {
    if (r.ok || r.status === 302) {
      if (modal) modal.remove();
      collapseAndRemove(container);
    }
  }).catch(console.error);
}

// ── Bind de ações ────────────────────────────────────────────────────────────
function bindActions(container) {
  const matchId     = container.dataset.matchId;
  const otherUserId = container.dataset.otherUserId;

  const clearBtn = container.querySelector('.swipe-btn-clear');
  const blockBtn = container.querySelector('.swipe-btn-block');

  onTap(clearBtn, () => {
    fetch(`/matches/${matchId}/clear_conversation`, {
      method: 'DELETE',
      headers: { 'X-CSRF-Token': csrfToken(), 'Accept': 'application/json' }
    }).then(r => {
      if (r.ok) {
        const preview = container.querySelector('.conv-last-message');
        if (preview) preview.textContent = 'Comece a conversar...';
        container.querySelector('.badge-your-turn')?.remove();
        const content = container.querySelector('.swipe-content');
        content.style.transform = '';
        content.classList.remove('is-swiped');
        container.classList.remove('is-dragging');
      }
    }).catch(console.error);
  });

  onTap(blockBtn, () => openBlockModal(container, otherUserId));
}

// ── CSS do Modal (injetado uma única vez) ─────────────────────────────────────
function injectModalStyles() {
  if (document.getElementById('sbm-styles')) return;
  const s = document.createElement('style');
  s.id = 'sbm-styles';
  s.textContent = `
    #swipe-block-modal { position: fixed; inset: 0; z-index: 9998; display: flex; align-items: flex-end; }
    .sbm-backdrop     { position: absolute; inset: 0; background: rgba(0,0,0,0.5); }
    .sbm-sheet        { position: relative; width: 100%; background: #1c1c1e; border-radius: 20px 20px 0 0;
                        padding: 24px 20px 36px; display: flex; flex-direction: column; gap: 10px; z-index: 1; }
    .sbm-title        { margin: 0 0 4px; font-size: 1rem; font-weight: 600; color: #fff; text-align: center; }
    .sbm-btn          { width: 100%; padding: 14px; border: none; border-radius: 12px; font-size: 0.95rem;
                        font-weight: 600; cursor: pointer; }
    .sbm-btn-block-only { background: #37474f; color: #fff; }
    .sbm-btn-report     { background: #b71c1c; color: #fff; }
    .sbm-btn-send-report{ background: #e53935; color: #fff; }
    .sbm-btn-cancel     { background: #2c2c2e; color: #aaa; }
    .sbm-report-area  { flex-direction: column; gap: 10px; }
    .sbm-textarea     { width: 100%; background: #2c2c2e; color: #fff; border: none; border-radius: 10px;
                        padding: 10px 12px; font-size: 0.9rem; resize: none; box-sizing: border-box; }
  `;
  document.head.appendChild(s);
}

// ── Busca por nome (lupa do cabeçalho) ───────────────────────────────────────
function initSearch() {
  const toggle = document.getElementById('conversations-search-toggle');
  const field  = document.getElementById('conversations-search-field');
  const input  = document.getElementById('conversations-search-input');
  if (!toggle || !field || !input || toggle.dataset.bound) return;
  toggle.dataset.bound = 'true';

  const empty = document.getElementById('conversations-search-empty');

  const filter = () => {
    const term = input.value.trim().toLowerCase();
    let visible = 0;
    document.querySelectorAll('#conversations-master-list .swipe-container').forEach(row => {
      const match = !term || (row.dataset.searchName || '').includes(term);
      row.hidden = !match;
      if (match) visible++;
    });
    if (empty) empty.hidden = visible > 0;
  };

  toggle.addEventListener('click', () => {
    field.hidden = !field.hidden;
    if (field.hidden) { input.value = ''; filter(); } else { input.focus(); }
  });
  input.addEventListener('input', filter);
}

// ── Init ──────────────────────────────────────────────────────────────────────
document.addEventListener('turbo:load', () => {
  initSearch();

  const list = document.getElementById('conversations-master-list');
  if (!list) return;

  injectModalStyles();

  list.querySelectorAll('.swipe-container').forEach(container => {
    initSwipe(container);
    bindActions(container);
  });

  document.addEventListener('touchstart', (e) => {
    closeAllSwipes(e.target.closest('.swipe-container'));
  }, { passive: true });
});
