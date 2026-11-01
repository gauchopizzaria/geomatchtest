import consumer from "./channels/consumer";

document.addEventListener('turbo:load', () => {
  const chatWindow = document.getElementById('chat-window');
  const messageInput = document.getElementById('message-input');
  const newMessageForm = document.getElementById('new-message-form');

  if (!chatWindow || !messageInput || !newMessageForm) return;

  const matchId = chatWindow.dataset.matchId;
  const currentUserId = parseInt(chatWindow.dataset.currentUserId, 10);

  let typingTimer;
  const TYPING_TIMEOUT = 3000;

  // =======================================================
  //   INJECT OVERLAYS (apenas uma vez por turbo:load)
  // =======================================================
  injectContextOverlay();
  injectReportSheet();

  // Configura long press nas mensagens já presentes no HTML
  chatWindow.querySelectorAll('.message-row').forEach(setupLongPress);

  // =======================================================
  //   SUBSCRIPTION
  // =======================================================
  const matchChannel = consumer.subscriptions.create(
    { channel: "MatchChannel", match_id: matchId },
    {
      connected() {
        console.log("Conectado ao match", matchId);
        scrollToBottom();
        chatWindow.querySelectorAll('.message-row.received').forEach(row => readObserver.observe(row));
      },

      received(data) {
        // -------------------------
        //    INDICADOR DE DIGITAÇÃO
        // -------------------------
        if (Object.prototype.hasOwnProperty.call(data, "typing")) {
          if (data.user_id == currentUserId) return;
          updateTypingIndicator(data);
          return;
        }

        // -------------------------
        //   ATUALIZAÇÃO DE STATUS
        // -------------------------
        if (data.action === 'status_update') {
          handleStatusUpdate(data);
          return;
        }

        // -------------------------
        //     NOVA MENSAGEM
        // -------------------------
        if (data.message) {
          appendMessageToDOM(data.message);

          if (data.message.sender_id !== currentUserId) {
            matchChannel.perform('mark_as_delivered', { message_id: data.message.id });
          }

          const conversationList = document.getElementById('conversations-master-list');
          const conversationRow = document.getElementById(`match-row-${data.message.match_id}`);

          if (conversationList && conversationRow) {
            conversationList.prepend(conversationRow);
            const lastMsgText = conversationRow.querySelector('.conv-last-message');
            if (lastMsgText) lastMsgText.innerText = data.message.content.substring(0, 30);
            const prefix = conversationRow.querySelector('.msg-prefix');
            if (prefix && data.message.sender_id !== currentUserId) prefix.remove();
          }
          return;
        }

        // -------------------------
        //   MENSAGEM APAGADA
        // -------------------------
        if (data.deleted_message_id) {
          const el = document.getElementById(`msg-${data.deleted_message_id}`);
          if (el) el.remove();
          return;
        }

        // -------------------------
        //   REAÇÃO ATUALIZADA
        // -------------------------
        if (data.reaction) {
          updateReactionDisplay(data.reaction);
          return;
        }
      },

      sendTypingStatus(isTyping) {
        this.perform("receive", { typing: isTyping });
      }
    }
  );

  // =======================================================
  //   INTERSECTION OBSERVER — MARCAR MENSAGENS COMO LIDAS
  // =======================================================
  const readObserver = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      const msgId = parseInt(entry.target.id.replace('msg-', ''), 10);
      matchChannel.perform('mark_as_read', { message_id: msgId });
      readObserver.unobserve(entry.target);
    });
  }, { root: chatWindow, threshold: 0.5 });

  // =======================================================
  //   LIMPAR CONVERSA
  // =======================================================
  const clearBtn = document.getElementById('clear-chat-btn');
  if (clearBtn) {
    const clearForm = clearBtn.closest('form');

    clearForm.addEventListener('submit', (e) => {
      e.preventDefault();

      fetch(clearForm.action, {
        method: "DELETE",
        headers: {
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content,
          "Accept": "application/json"
        }
      })
      .then(response => {
        if (response.ok) {
          const itemsToRemove = chatWindow.querySelectorAll('.message-row, .date-separator');
          itemsToRemove.forEach(m => m.remove());
          const menu = document.querySelector('[data-chat-menu-target="menu"]');
          if (menu) menu.hidden = true;
        }
      })
      .catch(err => console.error("Erro ao limpar:", err));
    });
  }

  // =======================================================
  //   INDICADOR DE DIGITAÇÃO
  // =======================================================
  function updateTypingIndicator(data) {
    const typing = document.getElementById("typing-indicator");
    if (!typing) return;

    if (data.typing === true) {
      const verifiedBadge = data.verified
        ? `<img src="/assets/icone-verificar.png" style="width: 14px; height: 14px; vertical-align: middle; margin-left: 2px;" title="Perfil Verificado">`
        : '';
      typing.innerHTML = `
        <div class="typing-user" style="color: #888; font-size: 0.8rem; margin-left: 20px; display: flex; align-items: center; gap: 3px;">
           ${data.user_name || "Alguém"}${verifiedBadge} está digitando...
        </div>
      `;
      typing.style.display = "block";
      scrollToBottom();
    } else {
      typing.style.display = "none";
    }
  }

  // =======================================================
  //   CAPTURA DE "ESTÁ DIGITANDO"
  // =======================================================
  if (messageInput) {
    messageInput.addEventListener("input", () => {
      matchChannel.sendTypingStatus(true);
      clearTimeout(typingTimer);
      typingTimer = setTimeout(() => {
        matchChannel.sendTypingStatus(false);
      }, TYPING_TIMEOUT);
    });
  }

  // =======================================================
  //   SUBMIT DA MENSAGEM
  //   (sem <form>: o envio é disparado pelo botão ou pelo Enter)
  // =======================================================
  const sendButton = document.getElementById('send-button');
  const messagesUrl = `${window.location.origin}/matches/${matchId}/messages`;

  function sendMessage() {
    const content = messageInput.value.trim();
    if (!content) return;

    messageInput.value = "";
    matchChannel.sendTypingStatus(false);

    fetch(messagesUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content,
      },
      body: JSON.stringify({ message: { content } }),
    })
    .then((response) => {
      if (!response.ok) console.error("Erro ao enviar mensagem");
    })
    .catch((error) => console.error(error));
  }

  if (sendButton) sendButton.addEventListener('click', sendMessage);

  messageInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  });

  // =======================================================
  //   APPEND NO DOM
  // =======================================================
  function appendMessageToDOM(message) {
    if (document.getElementById(`msg-${message.id}`)) return;

    const isSender = message.sender_id === currentUserId;
    const el = document.createElement("div");

    el.className = `message message-row ${isSender ? "sent" : "received"}`;
    el.id = `msg-${message.id}`;
    el.dataset.content = message.content || '';

    let avatarHtml = "";
    if (!isSender) {
      const avatarSrc = message.avatar_url;
      const displayName = message.user_name || "?";

      avatarHtml = `<div class="msg-avatar-container">`;
      if (avatarSrc) {
        avatarHtml += `<img class="msg-avatar" src="${avatarSrc}">`;
      } else {
        avatarHtml += `<div class="msg-avatar-placeholder">${displayName.charAt(0).toUpperCase()}</div>`;
      }
      avatarHtml += `</div>`;
    }

    const bubbleHtml = `<div class="message-bubble">${escapeHtml(message.content)}</div>`;
    const statusHtml = isSender
      ? `<div class="message-status status-${message.status || 'sent'}" data-status-id="${message.id}"></div>`
      : '';
    const tsHtml = `<span class="message-timestamp">${formatTime(message.created_at)}</span>`;

    el.innerHTML = avatarHtml + bubbleHtml + statusHtml + tsHtml;

    const slideContainer = chatWindow.querySelector('.messages-slide-container');
    const target = slideContainer || chatWindow;
    const typingIndicator = target.querySelector('#typing-indicator');
    if (typingIndicator) {
      target.insertBefore(el, typingIndicator);
    } else {
      target.appendChild(el);
    }

    // Configura long press na nova mensagem
    setupLongPress(el);

    if (!isSender) readObserver.observe(el);

    scrollToBottom();
  }

  // =======================================================
  //   LONG PRESS — DETECTAR PRESSIONAR E SEGURAR
  // =======================================================
  let longPressTimer = null;

  function setupLongPress(row) {
    // Evita dupla configuração
    if (row.dataset.lpSetup) return;
    row.dataset.lpSetup = "1";

    let startX, startY;

    row.addEventListener('touchstart', (e) => {
      e.preventDefault();
      e.stopPropagation();
      const touch = e.touches[0];
      startX = touch.clientX;
      startY = touch.clientY;
      longPressTimer = setTimeout(() => openContextMenu(row), 500);
    }, { passive: false });

    row.addEventListener('touchmove', (e) => {
      const touch = e.touches[0];
      const dx = Math.abs(touch.clientX - startX);
      const dy = Math.abs(touch.clientY - startY);
      if (dx > 10 || dy > 10) clearTimeout(longPressTimer);
    }, { passive: true });

    row.addEventListener('touchend',   () => clearTimeout(longPressTimer));
    row.addEventListener('touchcancel', () => clearTimeout(longPressTimer));
  }

  // =======================================================
  //   ABRIR MENU DE CONTEXTO
  // =======================================================
  function openContextMenu(row) {
    if (navigator.vibrate) navigator.vibrate(35);

    const overlay = document.getElementById('msg-context-overlay');
    const menu    = document.getElementById('msg-context-menu');
    if (!overlay || !menu) return;

    const msgId  = row.id.replace('msg-', '');
    const isSent = row.classList.contains('sent');
    const content = row.dataset.content || '';

    let html = '';

    // ----- MENSAGENS RECEBIDAS: barra de emojis -----
    if (!isSent) {
      html += `<div class="emoji-reaction-bar">`;
      ['👍', '❤️', '😂', '😮', '😢', '🙏'].forEach(emoji => {
        html += `<button class="emoji-btn" data-emoji="${emoji}" data-msg-id="${msgId}">${emoji}</button>`;
      });
      html += `</div>`;
    }

    // ----- MENSAGENS ENVIADAS: apagar -----
    if (isSent) {
      html += `
        <button class="context-action danger" id="ctx-delete-btn" data-msg-id="${msgId}">
          <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="3 6 5 6 21 6"></polyline>
            <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path>
          </svg>
          Apagar Mensagem
        </button>
      `;
    }

    // ----- MENSAGENS RECEBIDAS: denunciar -----
    if (!isSent) {
      const safeContent = content.replace(/"/g, '&quot;');
      html += `
        <button class="context-action warn" id="ctx-report-btn" data-msg-id="${msgId}" data-content="${safeContent}">
          <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z"></path>
            <line x1="4" y1="22" x2="4" y2="15"></line>
          </svg>
          Denunciar Mensagem
        </button>
      `;
    }

    menu.innerHTML = html;
    overlay.classList.remove('hidden');

    // Emoji buttons
    menu.querySelectorAll('.emoji-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        sendReaction(btn.dataset.msgId, btn.dataset.emoji);
        closeContextMenu();
      });
    });

    // Botão apagar
    const deleteBtn = menu.querySelector('#ctx-delete-btn');
    if (deleteBtn) {
      deleteBtn.addEventListener('click', () => {
        deleteMessage(deleteBtn.dataset.msgId);
        closeContextMenu();
      });
    }

    // Botão denunciar
    const reportBtn = menu.querySelector('#ctx-report-btn');
    if (reportBtn) {
      reportBtn.addEventListener('click', () => {
        closeContextMenu();
        openReportSheet(reportBtn.dataset.msgId, reportBtn.dataset.content);
      });
    }

    // Fechar ao clicar no backdrop
    document.getElementById('msg-context-backdrop').onclick = closeContextMenu;
  }

  function closeContextMenu() {
    const overlay = document.getElementById('msg-context-overlay');
    if (overlay) overlay.classList.add('hidden');
  }

  // =======================================================
  //   APAGAR MENSAGEM
  // =======================================================
  function deleteMessage(msgId) {
    fetch(`/matches/${matchId}/messages/${msgId}`, {
      method: 'DELETE',
      headers: {
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
      }
    })
    .then(res => {
      if (res.ok) {
        // Remove localmente (o ActionCable vai remover para os outros via broadcast)
        const el = document.getElementById(`msg-${msgId}`);
        if (el) el.remove();
      }
    })
    .catch(err => console.error('Erro ao apagar mensagem:', err));
  }

  // =======================================================
  //   ENVIAR REAÇÃO
  // =======================================================
  function sendReaction(msgId, emoji) {
    fetch(`/matches/${matchId}/messages/${msgId}/react`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
      },
      body: JSON.stringify({ emoji })
    })
    .catch(err => console.error('Erro ao enviar reação:', err));
  }

  // =======================================================
  //   EXIBIR REAÇÕES NO BALÃO
  // =======================================================
  function updateReactionDisplay(reaction) {
    const row = document.getElementById(`msg-${reaction.message_id}`);
    if (!row) return;

    let reactionBar = row.querySelector('.reaction-bar');

    const counts  = reaction.counts || {};
    const entries = Object.entries(counts);

    if (entries.length === 0) {
      if (reactionBar) reactionBar.remove();
      return;
    }

    const html = entries.map(([emoji, count]) =>
      `<span class="reaction-badge">${emoji}${count > 1 ? ` ${count}` : ''}</span>`
    ).join('');

    if (!reactionBar) {
      reactionBar = document.createElement('div');
      reactionBar.className = 'reaction-bar';
      row.appendChild(reactionBar);
    }

    reactionBar.innerHTML = html;
  }

  // =======================================================
  //   INJETAR OVERLAY DE CONTEXTO
  // =======================================================
  function injectContextOverlay() {
    if (document.getElementById('msg-context-overlay')) return;
    const el = document.createElement('div');
    el.id = 'msg-context-overlay';
    el.className = 'msg-context-overlay hidden';
    el.innerHTML = `
      <div id="msg-context-backdrop" class="msg-context-backdrop"></div>
      <div id="msg-context-menu" class="msg-context-menu"></div>
    `;
    document.body.appendChild(el);
  }

  // =======================================================
  //   INJETAR BOTTOM SHEET DE DENÚNCIA
  // =======================================================
  function injectReportSheet() {
    if (document.getElementById('msg-report-sheet')) return;
    const el = document.createElement('div');
    el.id = 'msg-report-sheet';
    el.className = 'msg-report-sheet hidden';
    el.innerHTML = `
      <div class="msg-report-backdrop" id="msg-report-backdrop"></div>
      <div class="msg-report-body">
        <h3>Denunciar Mensagem</h3>
        <p class="msg-report-preview"></p>
        <textarea id="msg-report-textarea" placeholder="Descreva o motivo da denúncia (opcional)..."></textarea>
        <div class="msg-report-actions">
          <button class="btn-cancel-report" id="msg-report-cancel">Cancelar</button>
          <button class="btn-submit-report" id="msg-report-submit">Denunciar</button>
        </div>
      </div>
    `;
    document.body.appendChild(el);

    document.getElementById('msg-report-backdrop').onclick = closeReportSheet;
    document.getElementById('msg-report-cancel').onclick   = closeReportSheet;
    document.getElementById('msg-report-submit').onclick   = submitReport;
  }

  function openReportSheet(msgId, content) {
    const sheet    = document.getElementById('msg-report-sheet');
    const preview  = sheet?.querySelector('.msg-report-preview');
    const textarea = document.getElementById('msg-report-textarea');
    if (!sheet) return;

    if (preview)  preview.textContent = content || '';
    if (textarea) textarea.value = '';
    sheet.dataset.msgId   = msgId;
    sheet.dataset.content = content || '';
    sheet.classList.remove('hidden');
  }

  function closeReportSheet() {
    const sheet = document.getElementById('msg-report-sheet');
    if (sheet) sheet.classList.add('hidden');
  }

  function submitReport() {
    const sheet    = document.getElementById('msg-report-sheet');
    const textarea = document.getElementById('msg-report-textarea');
    const msgId    = sheet?.dataset.msgId || '';
    const content  = sheet?.dataset.content || '';
    const extra    = textarea?.value.trim() || '';

    const description = `[Msg #${msgId}] "${content}"${extra ? ' — ' + extra : ''}`;

    fetch('/reports', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
      },
      body: JSON.stringify({ description })
    })
    .then(res => {
      if (res.ok || res.status === 201 || res.status === 204) {
        closeReportSheet();
      }
    })
    .catch(err => console.error('Erro ao denunciar:', err));
  }

  // =======================================================
  //   FUNÇÕES UTILITÁRIAS
  // =======================================================
  function escapeHtml(str) {
    if (!str) return "";
    return str.replace(/[&<>'"]/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;",
      '"': "&quot;", "'": "&#39;"
    }[c]));
  }

  function formatTime(isoString) {
    if (!isoString) return "";
    const d = new Date(isoString);
    return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  }

  function handleStatusUpdate(data) {
    const el = document.querySelector(`.message-status[data-status-id="${data.message_id}"]`);
    if (!el) return;
    el.className = `message-status status-${data.status}`;
  }

  function scrollToBottom() {
    chatWindow.scrollTop = chatWindow.scrollHeight;
  }

  // =======================================================
  //   AJUSTE DE TECLADO — Safari PWA + WkWebView (iOS app)
  // =======================================================
  const chatWrapper = document.querySelector('.chat-screen-wrapper');

  // Quanto a área visível precisa encolher para considerarmos o teclado aberto.
  const KEYBOARD_MIN_HEIGHT = 120;
  // Altura da tela SEM teclado — referência para detectar o teclado mesmo quando
  // o WKWebView redimensiona a página inteira (aí innerHeight também encolhe).
  let fullViewportHeight = Math.max(window.innerHeight, window.visualViewport ? window.visualViewport.height : 0);

  function adjustToViewport() {
    if (!chatWrapper) return;
    // visualViewport é preciso no Safari; em WkWebView pode não atualizar
    // window.innerHeight é o fallback confiável no WkWebView
    const vv     = window.visualViewport;
    const height = vv ? vv.height   : window.innerHeight;
    const top    = vv ? vv.offsetTop : 0;
    const focused = document.activeElement === messageInput;

    if (!focused) fullViewportHeight = Math.max(window.innerHeight, height);

    chatWrapper.style.height = height + 'px';
    chatWrapper.style.top    = top    + 'px';

    // Com o teclado aberto, o respiro de safe-area do rodapé (home indicator e,
    // no app iOS, a tab bar nativa: ~83px) fica atrás do teclado e virava um vão
    // vazio entre o campo e o teclado. A classe faz o CSS zerar esse respiro.
    const keyboardOpen = focused && (fullViewportHeight - height) > KEYBOARD_MIN_HEIGHT;
    chatWrapper.classList.toggle('keyboard-open', keyboardOpen);

    requestAnimationFrame(scrollToBottom);
  }

  // visualViewport.resize — funciona no Safari browser
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', adjustToViewport);
    window.visualViewport.addEventListener('scroll', adjustToViewport);
  }
  // window.resize — funciona no WkWebView onde visualViewport.resize pode não disparar
  window.addEventListener('resize', adjustToViewport);

  adjustToViewport();
  requestAnimationFrame(() => { adjustToViewport(); scrollToBottom(); });

  messageInput.addEventListener('focus', () => {
    // Dois retries para cobrir a animação do teclado iOS (~300ms)
    setTimeout(() => { adjustToViewport(); scrollToBottom(); }, 120);
    setTimeout(() => { adjustToViewport(); scrollToBottom(); }, 380);
  });

  messageInput.addEventListener('blur', () => {
    if (chatWrapper) {
      chatWrapper.style.height = '';
      chatWrapper.style.top    = '';
      chatWrapper.classList.remove('keyboard-open');
    }
    setTimeout(scrollToBottom, 100);
  });

  // --- Fechar teclado ao tocar na área de mensagens (comportamento WhatsApp) ---
  // Usa touchstart em fase de captura para pegar o toque antes do long-press
  chatWindow.addEventListener('touchstart', (e) => {
    if (document.activeElement !== messageInput) return;
    const tag = e.target.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'BUTTON') return;
    messageInput.blur();
  }, { passive: true, capture: true });

  // =======================================================
  //   DESLIZAR PARA REVELAR HORÁRIOS (estilo Instagram)
  // =======================================================
  (function setupTimestampReveal() {
    const slideContainer = chatWindow.querySelector('.messages-slide-container');
    if (!slideContainer) return;

    const MAX_SLIDE = 52;
    let startX = 0;
    let startY = 0;
    let active = false;
    let directionLocked = false;
    let isHorizontal = false;

    function onStart(x, y) {
      startX = x;
      startY = y;
      active = true;
      directionLocked = false;
      isHorizontal = false;
    }

    function onMove(x, y) {
      if (!active) return;
      const dx = startX - x;   // positivo = moveu para a esquerda
      const dy = Math.abs(y - startY);

      if (!directionLocked) {
        if (Math.abs(dx) < 5 && dy < 5) return;
        directionLocked = true;
        isHorizontal = Math.abs(dx) > dy;
      }

      if (!isHorizontal) return;

      const offset = Math.min(Math.max(dx, 0), MAX_SLIDE);
      slideContainer.classList.add('is-dragging');
      slideContainer.style.transform = `translateX(-${offset}px)`;
    }

    function onEnd() {
      if (!active) return;
      active = false;
      slideContainer.classList.remove('is-dragging');
      slideContainer.style.transform = '';
    }

    // — Touch (capture: true para não ser bloqueado pelo stopPropagation do long-press)
    chatWindow.addEventListener('touchstart', (e) => {
      const t = e.touches[0];
      onStart(t.clientX, t.clientY);
    }, { passive: true, capture: true });

    chatWindow.addEventListener('touchmove', (e) => {
      const t = e.touches[0];
      onMove(t.clientX, t.clientY);
      if (active && isHorizontal) e.preventDefault();
    }, { passive: false, capture: true });

    chatWindow.addEventListener('touchend',    onEnd, { capture: true });
    chatWindow.addEventListener('touchcancel', onEnd, { capture: true });

    // — Mouse (para testes no desktop)
    chatWindow.addEventListener('mousedown', (e) => onStart(e.clientX, e.clientY));
    chatWindow.addEventListener('mousemove', (e) => onMove(e.clientX, e.clientY));
    chatWindow.addEventListener('mouseup',   onEnd);
    chatWindow.addEventListener('mouseleave', onEnd);
  })();
});
