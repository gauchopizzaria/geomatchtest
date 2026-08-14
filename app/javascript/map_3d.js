import { toggleLiveTracking, startLiveTracking, resetTracking, isCurrentlyTracking } from "./live_location";
// Turf.js é esperado estar disponível globalmente (ex: via CDN)
// import * as turf from '@turf/turf'; // Removido para evitar erro de build se não instalado

// ===== KILL-SWITCH GLOBAL: despacha map:loaded após 10s não importa o que aconteça =====
// GPS tem timeout de 8s; o kill-switch precisa ser posterior para não revelar o mapa
// na posição errada enquanto o GPS ainda está resolvendo.
setTimeout(() => {
  const wrapper = document.querySelector('[data-controller="map-loader"]');
  if (wrapper) {
    console.log('[GeoMatch] Kill-switch global: disparando map:loaded após 10s');
    wrapper.dispatchEvent(new CustomEvent("map:loaded"));
  }
}, 10000);
// ========================================================================================


// --- Configurações e Estado Global ---
const INITIAL_RANGE_METERS = 150;
const FETCH_COOLDOWN_MS = 10000;
const STORAGE_KEYS = {
  RANGE: "geomatch_range",
  INVISIBLE_MODE: "geomatch_invisible_mode",
};

let map;
let mapResizeObserver = null;
let mapResizeInterval = null;
let fixedUserLat = null;
let fixedUserLng = null;
let currentRangeMeters = parseInt(localStorage.getItem(STORAGE_KEYS.RANGE)) || INITIAL_RANGE_METERS;
// Filtro de gênero SEMPRE inicia em "all" (Todos) — não persiste entre visitas.
// A escolha vale apenas enquanto o usuário está na tela do mapa.
let currentGenderFilter = "all";
let mapboxUserMarkers = {}; // Para gerenciar marcadores de usuários no Mapbox
let mapboxMarkerDistances = {}; // { userId: distanceKm } — para filtragem client-side por raio
let mapboxUserData = {}; // { userId: userData } — dados mais recentes por usuário
let lastUserFetchTime = 0;
let isFetchingNearby = false;
let nearbyFetchController = null;
let isUserInvisible = false;
let rotationAnimId = null;
let rotationTimer = null;
let isCinematicMode = false;
let cinematicPopup = null;
let activeMarkerEl = null;
let genderHudTimer = null;

const radarSourceId = 'radar-circle-source';
const radarLayerId = 'radar-circle-layer';

// --- Gender filter cycle definition ---
const GENDER_STATES = [
  { key: "all",        label: "Todos",       svgKeys: ["all"]       },
  { key: "male",       label: "Homens",      svgKeys: ["male"]      },
  { key: "female",     label: "Mulheres",    svgKeys: ["female"]    },
  { key: "non-binary", label: "Não Binário", svgKeys: ["nonbinary"] },
];

// Mesma geometria dos ícones do botão segmentado (users/_gender_filter_icon.html.erb)
// para o HUD exibir exatamente o símbolo selecionado. O gradiente gm-gold-grad usa
// gradientUnits="userSpaceOnUse" (0→24) — obrigatório para pintar as linhas retas.
const GENDER_SVGS = {
  all: `<svg viewBox="0 0 24 24" fill="none" stroke="url(#gm-gold-grad)" stroke-width="2" stroke-linecap="round" xmlns="http://www.w3.org/2000/svg">
    <circle cx="8" cy="8" r="4"/><circle cx="16" cy="8" r="4"/>
    <path d="M3 20c0-3.3 2.7-6 6-6M21 20c0-3.3-2.7-6-6-6" stroke-linejoin="round"/>
  </svg>`,
  male: `<svg viewBox="0 0 24 24" fill="none" stroke="url(#gm-gold-grad)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg">
    <circle cx="10" cy="14" r="6"/><path d="M14.5 9.5 20 4M14 4h6v6"/>
  </svg>`,
  female: `<svg viewBox="0 0 24 24" fill="none" stroke="url(#gm-gold-grad)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg">
    <circle cx="12" cy="9" r="6"/><path d="M12 15v7M9 19h6"/>
  </svg>`,
  nonbinary: `<svg viewBox="0 0 24 24" fill="none" stroke="url(#gm-gold-grad)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg">
    <rect x="5" y="5" width="14" height="14" rx="3" transform="rotate(45 12 12)"/>
  </svg>`,
};

// --- Haversine: distância métrica real entre dois pontos geográficos ---
function haversineDistanceM(lat1, lng1, lat2, lng2) {
  const R = 6371000;
  const φ1 = lat1 * Math.PI / 180;
  const φ2 = lat2 * Math.PI / 180;
  const Δφ = (lat2 - lat1) * Math.PI / 180;
  const Δλ = (lng2 - lng1) * Math.PI / 180;
  const a = Math.sin(Δφ / 2) ** 2 + Math.cos(φ1) * Math.cos(φ2) * Math.sin(Δλ / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// --- Funções de Interface (UI) ---

// Função para exibir mensagens rápidas (Toasts) — mantida para uso genérico
function showQuickMessage(text) {
  let toast = document.getElementById("gender-toast");
  if (!toast) {
    toast = document.createElement("div");
    toast.id = "gender-toast";
    document.body.appendChild(toast);
  }
  toast.textContent = text;
  toast.classList.add("show");
  setTimeout(() => { toast.classList.remove("show"); }, 2000);
}

// HUD imersivo para o filtro de gênero
function showGenderHUD(state) {
  const hud      = document.getElementById("gender-hud");
  const iconsEl  = document.getElementById("gender-hud-icons");
  const labelEl  = document.getElementById("gender-hud-label");
  if (!hud || !iconsEl || !labelEl) return;

  // Cancela timer anterior (clique rápido)
  if (genderHudTimer) { clearTimeout(genderHudTimer); genderHudTimer = null; }

  // Injeta ícones e texto
  iconsEl.innerHTML = state.svgKeys.map(k => GENDER_SVGS[k]).join("");
  iconsEl.dataset.count = state.svgKeys.length;
  labelEl.textContent = state.label;

  // Exibe
  hud.classList.remove("fade-out");
  hud.classList.add("show");

  // Esconde após 3s com fade-out suave
  genderHudTimer = setTimeout(() => {
    hud.classList.remove("show");
    hud.classList.add("fade-out");
    genderHudTimer = setTimeout(() => {
      hud.classList.remove("fade-out");
      genderHudTimer = null;
    }, 500);
  }, 3000);
}

function showTrackingToast(text) {
  let toast = document.getElementById("tracking-toast");
  if (!toast) {
    toast = document.createElement("div");
    toast.id = "tracking-toast";
    document.body.appendChild(toast);
  }
  toast.textContent = text;
  toast.classList.remove("show");
  setTimeout(() => {
    toast.classList.add("show");
  }, 10);
  if (window.trackingToastTimer) clearTimeout(window.trackingToastTimer);
  window.trackingToastTimer = setTimeout(() => {
    toast.classList.remove("show");
  }, 3000);
}

function showLoadingAnimation() {
  const usersList = document.getElementById("users-list");
  const usersCountElement = document.getElementById("nearby-count");
  if (usersList) {
    usersList.innerHTML = `
      <li class="loading-skeleton"><div class="skeleton-avatar"></div><div class="skeleton-text"><div class="skeleton-line"></div></div></li>
      <li class="loading-skeleton"><div class="skeleton-avatar"></div><div class="skeleton-text"><div class="skeleton-line"></div></div></li>
    `;
  }
  if (usersCountElement) usersCountElement.textContent = "...";
}

function hideLoadingAnimation() {
  // Implementação pode ser vazia ou remover skeletons
}

function closeUserPopup() {
  const popup = document.getElementById("user-popup");
  if (popup) {
    popup.classList.add("hidden");
    popup.classList.remove("show");
    const content = popup.querySelector(".popup-content-fullscreen");
    if(content) content.classList.remove("expanded");
    const rejectInput = document.getElementById("popup-reject-input");
    const likeInput = document.getElementById("popup-like-input");
    if(rejectInput) rejectInput.value = "";
    if(likeInput) likeInput.value = "";
  }
}

// --- Funções Cinematográficas ---

function stopRotation() {
  if (rotationAnimId) { cancelAnimationFrame(rotationAnimId); rotationAnimId = null; }
  if (rotationTimer) { clearTimeout(rotationTimer); rotationTimer = null; }
}

function startTimedRotation(onComplete) {
  stopRotation();
  const startBearing = map.getBearing();
  const startTime = performance.now();
  const DURATION = 30000;

  function rotate(now) {
    const elapsed = now - startTime;
    if (elapsed >= DURATION) {
      rotationAnimId = null;
      if (isCinematicMode && onComplete) onComplete();
      return;
    }
    const progress = elapsed / DURATION;
    // Curva de seno: mais suave que quadrática em movimentos longos
    const easedProgress = -(Math.cos(Math.PI * progress) - 1) / 2;
    map.setBearing(startBearing + 360 * easedProgress);
    rotationAnimId = requestAnimationFrame(rotate);
  }

  rotationAnimId = requestAnimationFrame(rotate);
}

function resetCamera() {
  stopRotation();
  isCinematicMode = false;
  document.body.classList.remove('cinematic-mode');
  map.easeTo({ pitch: 0, bearing: 0, duration: 800, easing: t => t });
}

function calculateAge(birthdate) {
  if (!birthdate) {
    console.error('[GeoMatch] user.birthdate ausente — usando idade padrão 25');
    return 25;
  }
  const birth = new Date(birthdate);
  if (isNaN(birth.getTime())) {
    console.error('[GeoMatch] user.birthdate inválido:', birthdate, '— usando idade padrão 25');
    return 25;
  }
  const today = new Date();
  let age = today.getFullYear() - birth.getFullYear();
  const monthDiff = today.getMonth() - birth.getMonth();
  if (monthDiff < 0 || (monthDiff === 0 && today.getDate() < birth.getDate())) age--;
  return age;
}

function openCinematicPopup(user) {
  const overlay = document.getElementById('mini-card-overlay');
  if (!overlay) return;

  const username = user.username || user.display_name || 'Usuário';
  const age = calculateAge(user.birthdate);
  const distVal = user.distance_km || user.distance;

  // Título: "Username, Idade"
  const nameEl = document.getElementById('mco-name');
  nameEl.innerHTML = `<span style="font-weight:bold">${username}</span><span style="font-weight:normal">, ${age}</span>`;

  // Avatar
  document.getElementById('mco-avatar').src = user.avatar_url || '/default-avatar.png';

  // Badge de verificado
  const verifiedBadge = document.getElementById('mco-verified-badge');
  if (verifiedBadge) verifiedBadge.style.display = user.verified ? 'block' : 'none';

  // Distância
  const distEl = document.getElementById('mco-distance');
  distEl.textContent = distVal ? `a ${distVal} km` : '';
  distEl.style.display = distVal ? '' : 'none';

  // Registra o clique em "Ver Perfil" — clona para evitar listeners acumulados
  const btn = document.getElementById('mco-view-btn');
  const newBtn = btn.cloneNode(true);
  btn.parentNode.replaceChild(newBtn, btn);
  newBtn.addEventListener('click', () => { closeCinematicPopup(); showUserPopup(user); });

  // Anima entrada de baixo para cima
  overlay.style.display = 'block';
  requestAnimationFrame(() => {
    overlay.style.opacity = '1';
    overlay.style.transform = 'translateX(-50%) translateY(0)';
  });
}

function closeCinematicPopup() {
  const overlay = document.getElementById('mini-card-overlay');
  if (overlay) {
    overlay.style.opacity = '0';
    overlay.style.transform = 'translateX(-50%) translateY(30px)';
    setTimeout(() => { overlay.style.display = 'none'; }, 300);
  }
  if (activeMarkerEl) { activeMarkerEl.style.opacity = '1'; activeMarkerEl = null; }
  resetCamera();
}

// --- Funções de Mapa e Dados ---

function updateRadarVisuals() {
  const container = document.querySelector(".discover-fullscreen-container");
  if (!map || !fixedUserLat || !container) return;

  // 1. Posicionamento do Spotlight (CSS)
  const point = map.project([fixedUserLng, fixedUserLat]);
  container.style.setProperty('--radar-x', `${point.x}px`);
  container.style.setProperty('--radar-y', `${point.y}px`);

  // 2. Escala do Raio via projeção direta — correto em qualquer zoom/pitch,
  //    evita o erro da constante 256px-vs-512px dos tiles do Mapbox GL.
  const latDelta = (currentRangeMeters / 1000) / 111.32;
  const edgePoint = map.project([fixedUserLng, fixedUserLat + latDelta]);
  const radiusInPixels = Math.abs(edgePoint.y - point.y);
  container.style.setProperty('--radar-radius', `${radiusInPixels}px`);

  // 3. Círculo Geográfico (Turf.js no Mapbox) — isolado em try/catch: se o turf
  // (CDN) não carregar ou o style trocar no meio, a ancoragem CSS acima já rodou
  // e o círculo continua preso à localização do usuário.
  try {
    if (map.isStyleLoaded() && typeof turf !== 'undefined') {
      const center = [fixedUserLng, fixedUserLat];
      const circle = turf.circle(center, currentRangeMeters / 1000, { steps: 64, units: 'kilometers' });

      if (map.getSource(radarSourceId)) {
        map.getSource(radarSourceId).setData(circle);
      } else {
        map.addSource(radarSourceId, { 'type': 'geojson', 'data': circle });
        map.addLayer({
          'id': radarLayerId,
          'type': 'fill',
          'source': radarSourceId,
          'paint': { 'fill-color': '#F4E4BC', 'fill-opacity': 0.1 }
        });
      }
    }
  } catch (e) {
    console.error('[GeoMatch] Falha ao desenhar círculo geojson do radar:', e);
  }
}

function filterMarkersByRange() {
  const limitKm = currentRangeMeters / 1000;
  // 75m de tolerância de GPS: dois celulares encostados podem registrar 50-100m de
  // distância devido à imprecisão da antena. Sem essa margem, raios curtos (<150m)
  // ocultam usuários fisicamente próximos cujas coordenadas têm erro de GPS.
  const GPS_TOL_KM = 0.075;
  const effectiveLimitKm = limitKm + GPS_TOL_KM;
  let visibleCount = 0;

  Object.entries(mapboxMarkerDistances).forEach(([userId, distKm]) => {
    const marker = mapboxUserMarkers[userId];
    if (!marker) return;
    const visible = distKm <= effectiveLimitKm;
    marker.getElement().style.display = visible ? '' : 'none';
    if (visible) visibleCount++;
  });

  const countEl = document.getElementById("nearby-count");
  if (countEl) countEl.textContent = visibleCount;

  document.querySelectorAll('#users-list .user-list-item[data-dist-km]').forEach(li => {
    li.style.display = parseFloat(li.dataset.distKm) <= effectiveLimitKm ? '' : 'none';
  });
}

async function loadNearbyUsers(latitude, longitude, rangeMeters, genderFilter) {
  // Cancela qualquer fetch em andamento — garante que o filtro ativo sempre vence.
  if (nearbyFetchController) nearbyFetchController.abort();
  nearbyFetchController = new AbortController();
  isFetchingNearby = true;
  showLoadingAnimation();
  const usersList = document.getElementById("users-list");
  const usersCountElement = document.getElementById("nearby-count");
  const assetsData = document.getElementById('assets-data');
  const frameUrl = assetsData ? assetsData.dataset.frameUrl : '';
  const verifiedUrl = assetsData ? assetsData.dataset.verifiedUrl : '';

  try {
    let url = `/users/nearby?latitude=${latitude}&longitude=${longitude}&range=${rangeMeters}`;
    if (genderFilter !== "all") url += `&gender=${genderFilter}`;

    const response = await fetch(url, { signal: nearbyFetchController.signal });
    if (!response.ok) throw new Error("Falha na rede");
    const users = await response.json();
    console.log('[GeoMatch Debug] Usuários:', users);

    if (users.length === 0) {
      // Resposta vazia — não limpa marcadores existentes.
      // O GPS recém-desbloqueado pode ter jitter e colocar o utilizador ligeiramente
      // fora do raio por um ciclo. Os marcadores persistem até a próxima resposta com dados.
      if (!Object.keys(mapboxUserMarkers).length) {
        if (usersList) usersList.innerHTML = '<li class="text-center loading-text">Ninguém por perto...</li>';
        if (usersCountElement) usersCountElement.textContent = "0";
      }
      hideLoadingAnimation();
      return;
    }

    // Só limpa e reconstrói quando há dados frescos para repor
    Object.values(mapboxUserMarkers).forEach(m => m.remove());
    mapboxUserMarkers = {};
    mapboxMarkerDistances = {};
    if (usersList) usersList.innerHTML = "";

    users.forEach(user => {
      const distDisplay = (user.distance_km || user.distance || 0);

      const avatarHtml = `
        <div class="avatar-frame-wrapper">
          <img src="${user.avatar_url || '/default-avatar.png'}" class="avatar-user-img">
          <img src="${frameUrl}" class="avatar-frame-overlay">
        </div>
      `;

      let uLat = parseFloat(user.latitude);
      let uLng = parseFloat(user.longitude);

      // Polar scatter + rigid Haversine clamp:
      // after jitter, verify the real geographic distance and force the point
      // strictly inside the radar boundary — the avatar center never escapes the ring.
      {
        const mPerDegLat = 111000;
        const mPerDegLng = 111000 * Math.cos(fixedUserLat * Math.PI / 180);
        const maxScatterM = Math.min(25, currentRangeMeters * 0.12);
        const angle = Math.random() * 2 * Math.PI;
        const r = Math.random() * maxScatterM;
        uLat += (r * Math.sin(angle)) / mPerDegLat;
        uLng += (r * Math.cos(angle)) / mPerDegLng;

        // Hard clamp: Haversine gives the true arc distance; Euclidean vector
        // is used only for direction (safe at sub-300m scale).
        const limitM = currentRangeMeters - 2;
        const realDistM = haversineDistanceM(fixedUserLat, fixedUserLng, uLat, uLng);
        if (realDistM > limitM) {
          const dLatM = (uLat - fixedUserLat) * mPerDegLat;
          const dLngM = (uLng - fixedUserLng) * mPerDegLng;
          const vecLen = Math.sqrt(dLatM * dLatM + dLngM * dLngM);
          if (vecLen > 0) {
            const scale = limitM / vecLen;
            uLat = fixedUserLat + (dLatM * scale) / mPerDegLat;
            uLng = fixedUserLng + (dLngM * scale) / mPerDegLng;
          } else {
            uLat = fixedUserLat + limitM / mPerDegLat;
            uLng = fixedUserLng;
          }
        }
      }

      if (!isNaN(uLat) && !isNaN(uLng)) {
        const el = document.createElement('div');
        el.className = 'premium-marker';
        el.innerHTML = `<img src="${user.avatar_url || '/default-avatar.png'}" class="premium-marker-img" alt="${user.username || ''}">`;

        const marker = new mapboxgl.Marker(el, { anchor: 'center' })
          .setLngLat([uLng, uLat])
          .addTo(map);
        mapboxUserMarkers[user.id] = marker;
        mapboxMarkerDistances[user.id] = user.distance_km || 0;
        mapboxUserData[user.id] = user;
        el.addEventListener('click', (e) => {
          e.stopPropagation();
          if (activeMarkerEl && activeMarkerEl !== el) activeMarkerEl.style.opacity = '1';
          activeMarkerEl = el;
          el.style.opacity = '0';
          isCinematicMode = true;
          document.body.classList.add('cinematic-mode');
          stopRotation();
          map.flyTo({ center: [uLng, uLat], zoom: 18, pitch: 60, duration: 2000, essential: true });
          openCinematicPopup(user);
          map.once('moveend', () => {
            setTimeout(() => {
              if (!isCinematicMode) return;
              startTimedRotation(null);
            }, 50);
          });
        });
      }

      if (usersList) {
        const isOnline = user.online;
        const li = document.createElement("li");
        li.className = "user-list-item";
        li.dataset.distKm = user.distance_km || 0;
        li.innerHTML = `
          ${avatarHtml}
          <div class="user-list-info">
              <div class="user-list-name-row" style="display: flex; align-items: center; gap: 5px;">
                  <span class="user-list-name">${user.username || user.display_name || 'Usuário'}</span>
                  ${user.verified ? `<img src="${verifiedUrl}" style="width: 14px; height: 14px;" title="Perfil Verificado">` : ''}
                  <span class="header-status" style="font-size: 0.7rem;">
                      <span class="${isOnline ? 'dot-online' : 'dot-offline'}">●</span>
                      ${isOnline ? 'Online' : 'Offline'}
                  </span>
              </div>
              <div class="user-list-distance">${distDisplay} km</div>
          </div>
        `;
        li.addEventListener("click", () => {
          if (!isNaN(uLat) && !isNaN(uLng)) {
            // Colapsa a gaveta para liberar a visão do mapa
            const sheet = document.querySelector('.users-bottom-sheet');
            if (sheet) sheet.style.height = '25vh';

            // Corrige referência: getElement() já retorna a .premium-marker div
            const markerEl = mapboxUserMarkers[user.id]?.getElement();
            if (activeMarkerEl && activeMarkerEl !== markerEl) activeMarkerEl.style.opacity = '1';
            if (markerEl) { activeMarkerEl = markerEl; markerEl.style.opacity = '0'; }

            isCinematicMode = true;
            document.body.classList.add('cinematic-mode');
            stopRotation();
            map.flyTo({ center: [uLng, uLat], zoom: 18, pitch: 60, duration: 2000, essential: true });
            openCinematicPopup(user);
            map.once('moveend', () => {
              setTimeout(() => {
                if (!isCinematicMode) return;
                startTimedRotation(null);
              }, 50);
            });
          }
        });
        usersList.appendChild(li);
      }
    });

    filterMarkersByRange();
    hideLoadingAnimation();
  } catch (error) {
    if (error.name === 'AbortError') return; // fetch cancelado por novo filtro — silencioso
    console.error("Erro ao carregar usuários próximos:", error);
    hideLoadingAnimation();
    if (usersList) usersList.innerHTML = '<li class="text-center loading-text">Erro ao carregar usuários.</li>';
  } finally {
    isFetchingNearby = false;
    nearbyFetchController = null;
  }
}

// --- Tempo Real: handler para dados recebidos via MapChannel ---
function _handleMapRealtime(data) {
  const currentUserId = document.querySelector('meta[name="current-user-id"]')?.content;
  if (!map || !window._mapIsReady) return;
  if (String(data.user_id) === String(currentUserId)) return; // nunca duplicar o próprio usuário

  const uid = data.user_id;

  // --- SAÍDA: remove marcador quando o usuário desconecta ---
  if (data.action === "leave") {
    const m = mapboxUserMarkers[uid];
    if (m) { m.remove(); delete mapboxUserMarkers[uid]; }
    delete mapboxMarkerDistances[uid];
    delete mapboxUserData[uid];
    filterMarkersByRange();
    return;
  }

  // --- UPDATE: adiciona ou reposiciona marcador ---
  if (data.action !== "update") return;
  if (!fixedUserLat || !fixedUserLng) return;

  // Respeita o filtro de gênero ativo — realtime não deve bypassar a seleção do usuário
  if (currentGenderFilter !== 'all') {
    const GENDER_REALTIME_MAP = {
      'male':       ['homem', 'male'],
      'female':     ['mulher', 'female'],
      'non-binary': ['não binário', 'nao binario', 'non-binary', 'não-binário']
    };
    const allowed = GENDER_REALTIME_MAP[currentGenderFilter] || [];
    const incomingGender = (data.gender || '').toLowerCase();
    if (!allowed.includes(incomingGender)) {
      // Remove do mapa se estava visível com filtro anterior
      const stale = mapboxUserMarkers[uid];
      if (stale) { stale.remove(); delete mapboxUserMarkers[uid]; delete mapboxMarkerDistances[uid]; delete mapboxUserData[uid]; filterMarkersByRange(); }
      return;
    }
  }

  // Distância real em metros — respeita o filtro de raio atual
  const realDistM = haversineDistanceM(fixedUserLat, fixedUserLng, data.lat, data.lng);
  if (realDistM > currentRangeMeters) {
    // Saiu do radar: remove se existia
    const m = mapboxUserMarkers[uid];
    if (m) { m.remove(); delete mapboxUserMarkers[uid]; }
    delete mapboxMarkerDistances[uid];
    delete mapboxUserData[uid];
    filterMarkersByRange();
    return;
  }

  // Remove marcador anterior (se existir) para recriar com nova posição
  const existing = mapboxUserMarkers[uid];
  if (existing) { existing.remove(); delete mapboxUserMarkers[uid]; }

  // Aplica scatter de privacidade idêntico ao de loadNearbyUsers
  let uLat = data.lat;
  let uLng = data.lng;
  {
    const mPerDegLat = 111000;
    const mPerDegLng  = 111000 * Math.cos(fixedUserLat * Math.PI / 180);
    const maxScatterM = Math.min(25, currentRangeMeters * 0.12);
    const angle = Math.random() * 2 * Math.PI;
    const r     = Math.random() * maxScatterM;
    uLat += (r * Math.sin(angle)) / mPerDegLat;
    uLng += (r * Math.cos(angle)) / mPerDegLng;
    const limitM    = currentRangeMeters - 2;
    const distCheck = haversineDistanceM(fixedUserLat, fixedUserLng, uLat, uLng);
    if (distCheck > limitM) {
      const dLatM  = (uLat - fixedUserLat) * mPerDegLat;
      const dLngM  = (uLng - fixedUserLng) * mPerDegLng;
      const vecLen = Math.sqrt(dLatM * dLatM + dLngM * dLngM);
      if (vecLen > 0) {
        const scale = limitM / vecLen;
        uLat = fixedUserLat + (dLatM * scale) / mPerDegLat;
        uLng = fixedUserLng + (dLngM * scale) / mPerDegLng;
      }
    }
  }

  const distKm = parseFloat((realDistM / 1000).toFixed(1));
  const userData = {
    id: uid, username: data.username, latitude: data.lat, longitude: data.lng,
    avatar_url: data.avatar_url, verified: data.verified, bio: data.bio,
    city: data.city, gender: data.gender, interested_in: data.interested_in,
    hobbies_list: data.hobbies_list, birthdate: data.birthdate,
    distance_km: distKm, online: true
  };
  mapboxUserData[uid] = userData;

  const el = document.createElement('div');
  el.className = 'premium-marker';
  el.innerHTML = `<img src="${data.avatar_url || '/default-avatar.png'}" class="premium-marker-img" alt="${data.username || ''}">`;

  const marker = new mapboxgl.Marker(el, { anchor: 'center' })
    .setLngLat([uLng, uLat])
    .addTo(map);
  mapboxUserMarkers[uid] = marker;
  mapboxMarkerDistances[uid] = distKm;

  el.addEventListener('click', (e) => {
    e.stopPropagation();
    const latest = mapboxUserData[uid] || userData;
    if (activeMarkerEl && activeMarkerEl !== el) activeMarkerEl.style.opacity = '1';
    activeMarkerEl = el;
    el.style.opacity = '0';
    isCinematicMode = true;
    document.body.classList.add('cinematic-mode');
    stopRotation();
    map.flyTo({ center: [uLng, uLat], zoom: 18, pitch: 60, duration: 2000, essential: true });
    openCinematicPopup(latest);
    map.once('moveend', () => {
      setTimeout(() => { if (!isCinematicMode) return; startTimedRotation(null); }, 50);
    });
  });

  filterMarkersByRange();
}

function showUserPopup(user) {
  const userPopup = document.getElementById("user-popup");
  if (!userPopup) return;

  userPopup.dataset.userId = user.id;

  // --- Carrossel de fotos ---
  const carousel   = document.getElementById('popup-carousel');
  const dotsWrap   = document.getElementById('popup-carousel-dots');
  if (carousel) {
    const photos = (user.photos_urls && user.photos_urls.length > 0)
      ? user.photos_urls
      : [user.avatar_url || '/default-avatar.png'];

    carousel.innerHTML = photos
      .map(url => `<img src="${url}" class="dsc-carousel-slide" draggable="false">`)
      .join('');
    carousel.scrollLeft = 0;

    // Limpa zonas de toque do usuário anterior
    carousel.parentElement.querySelectorAll('.dsc-tap-zone').forEach(z => z.remove());

    if (dotsWrap) {
      dotsWrap.innerHTML = photos.length > 1
        ? photos.map((_, i) => `<span class="dsc-dot${i === 0 ? ' active' : ''}"></span>`).join('')
        : '';

      const updateDots = () => {
        const idx = Math.round(carousel.scrollLeft / Math.max(carousel.offsetWidth, 1));
        dotsWrap.querySelectorAll('.dsc-dot').forEach((d, i) =>
          d.classList.toggle('active', i === idx)
        );
      };

      // scrollend dispara uma vez ao parar (preciso); fallback com debounce para browsers antigos
      if ('onscrollend' in window) {
        carousel.onscrollend = updateDots;
        carousel.onscroll = null;
      } else {
        let t;
        carousel.onscroll = () => { clearTimeout(t); t = setTimeout(updateDots, 80); };
      }

      if (photos.length > 1) {
        const goTo = (idx) => carousel.scrollTo({ left: idx * carousel.offsetWidth, behavior: 'smooth' });
        const wrapper = carousel.parentElement;

        const prev = document.createElement('div');
        prev.className = 'dsc-tap-zone dsc-tap-prev';
        prev.addEventListener('click', () => {
          const cur = Math.round(carousel.scrollLeft / Math.max(carousel.offsetWidth, 1));
          if (cur > 0) goTo(cur - 1);
        });

        const next = document.createElement('div');
        next.className = 'dsc-tap-zone dsc-tap-next';
        next.addEventListener('click', () => {
          const cur = Math.round(carousel.scrollLeft / Math.max(carousel.offsetWidth, 1));
          if (cur < photos.length - 1) goTo(cur + 1);
        });

        wrapper.appendChild(prev);
        wrapper.appendChild(next);
      }
    }
  }

  // --- Nome ---
  const nameEl = userPopup.querySelector("#popup-username");
  if (nameEl) nameEl.textContent = user.username || user.display_name || "Usuário";

  // --- Idade ---
  const ageEl = userPopup.querySelector("#popup-age");
  if (ageEl) {
    const age = user.age ?? (user.birthdate ? calculateAge(user.birthdate) : null);
    ageEl.textContent = age ? `, ${age}` : '';
  }

  // --- Verificado ---
  const verifiedBadge = userPopup.querySelector("#popup-verified-badge");
  if (verifiedBadge) verifiedBadge.style.display = user.verified ? "inline-block" : "none";

  // --- Localização ---
  const loc = userPopup.querySelector("#popup-location");
  if (loc) loc.textContent = user.city || "Localização desconhecida";

  // --- Distância ---
  const distEl = userPopup.querySelector("#popup-distance");
  const distVal = user.distance_km || user.distance;
  if (distEl) distEl.textContent = distVal ? `${distVal} km` : "";

  const bio = userPopup.querySelector("#popup-bio");
  if(bio) bio.textContent = user.bio || "Não informado!";

  const genderElement = userPopup.querySelector("#popup-gender");
  if (genderElement) {
    const genderValue = user.gender ? user.gender.toLowerCase() : "";
    let genderText = "Não informado";
    if (genderValue === 'homem' || genderValue === 'male') {
      genderText = 'Masculino';
    } else if (genderValue === 'mulher' || genderValue === 'female') {
      genderText = 'Feminino';
    } else if (genderValue === 'não binário' || genderValue === 'nao binario' || genderValue === 'non-binary') {
      genderText = 'Não Binário';
    } else if (genderValue === 'nao-dizer') {
      genderText = 'Prefere não dizer';
    }
    genderElement.textContent = genderText;
  }

  const interest = userPopup.querySelector("#popup-interest");
  if(interest) interest.textContent = user.interested_in ? `Busca: ${user.interested_in}` : "Busca: Todos";

  const tagsContainer = userPopup.querySelector("#popup-tags-container");
  const tagsList = userPopup.querySelector("#popup-tags-list");
  
  if(tagsList) {
      tagsList.innerHTML = ""; 
      if (user.hobbies_list && Array.isArray(user.hobbies_list) && user.hobbies_list.length > 0) {
          tagsContainer.style.display = "block";
          user.hobbies_list.forEach(tag => {
              const span = document.createElement("span");
              span.className = "tag-pill";
              span.textContent = tag;
              tagsList.appendChild(span);
          });
      } else {
          tagsContainer.style.display = "none";
      }
  }

  const content = userPopup.querySelector(".popup-content-fullscreen");
  if(content) content.classList.remove("expanded");

  const forms = [
      document.getElementById("popup-reject-form"),
      document.getElementById("popup-chat-form"),
      document.getElementById("popup-like-form")
  ];

  forms.forEach(form => {
        if (form) {
          let baseUrl = form.getAttribute("data-base-action");
          if (!baseUrl) { baseUrl = form.action; form.setAttribute("data-base-action", baseUrl); }
          const newUrl = baseUrl.replace(/\/0\/?(\?.*)?$/, '/' + user.id + '$1');
          if (newUrl.includes("user_id=")) {
              form.action = newUrl.replace("user_id=0", `user_id=${user.id}`);
          } else {
              form.action = newUrl;
          }
        }
  });

  // --- Botões de segurança: Denunciar / Bloquear ---
  const reportBtn = document.getElementById('popup-btn-report');
  const blockBtn  = document.getElementById('popup-btn-block');

  if (reportBtn) {
    reportBtn.onclick = () => {
      if (typeof Turbo !== 'undefined') {
        Turbo.visit(`/report_incident?user_id=${user.id}`);
      } else {
        window.location.href = `/report_incident?user_id=${user.id}`;
      }
    };
  }

  if (blockBtn) {
    const displayName = user.username || user.display_name || 'Usuário';
    blockBtn.onclick = () => openBlockConfirm(displayName, `/users/${user.id}/block`);
  }

  // --- Botão "Enviar Mimo": leva ao catálogo já com o destinatário selecionado ---
  const mimoBtn = document.getElementById('popup-btn-mimo');
  if (mimoBtn) {
    mimoBtn.onclick = () => {
      const url = `/mimos/catalogo?receiver_id=${user.id}`;
      if (typeof Turbo !== 'undefined') {
        Turbo.visit(url);
      } else {
        window.location.href = url;
      }
    };
  }

  userPopup.classList.remove("hidden");
  userPopup.classList.add("show");
}

function initializeMapAndLocation() {
  // ===== VERIFICAÇÃO DE SEGURANÇA =====
  if (typeof mapboxgl === 'undefined') {
    console.error('[GeoMatch] CRÍTICO: mapboxgl não está definido globalmente!');
    console.error('[GeoMatch] Verifique se o script Mapbox GL está carregando antes do módulo ES6');
    return;
  }

  const mapboxTokenEl = document.querySelector('meta[name="mapbox-token"]');
  if (!mapboxTokenEl) {
    console.error('[GeoMatch] CRÍTICO: meta tag mapbox-token não encontrada!');
    return;
  }

  const mapboxToken = mapboxTokenEl.content;
  if (!mapboxToken) {
    console.error('[GeoMatch] CRÍTICO: mapbox-token está vazio! Verifique ENV[MAPBOX_TOKEN]');
    return;
  }

  mapboxgl.accessToken = mapboxToken;
  console.log('[GeoMatch] Mapbox token configurado ✓');

  const mapElement = document.getElementById('map-3d');
  if (!mapElement) {
    console.error('[GeoMatch] CRÍTICO: elemento #map-3d não encontrado no DOM!');
    return;
  }

  mapElement.innerHTML = '';

  // --- Prioridade 2 (Banco de Dados): lê coords do data-attribute injetado pela view ---
  // Se o GPS for negado ou demorar, o mapa ao menos inicia na região correta do usuário,
  // pré-carregando tiles úteis mesmo que o loader ainda cubra tudo.
  const dbLat = parseFloat(mapElement.dataset.userLat) || null;
  const dbLng = parseFloat(mapElement.dataset.userLng) || null;
  const hasDbCoords = dbLat && dbLng && dbLat !== 0 && dbLng !== 0;
  const initialCenter = hasDbCoords ? [dbLng, dbLat] : [-39.2781, -14.7876];

  // Inicia em 2D (pitch 0, bearing 0)
  console.log('[GeoMatch] Criando Mapbox Map com center:', initialCenter, 'hasDbCoords:', hasDbCoords);
  map = new mapboxgl.Map({
    container: 'map-3d',
    style: 'mapbox://styles/mapbox/standard',
    center: initialCenter, // DB coords ou fallback — o loader cobre qualquer salto residual
    zoom: 14,
    pitch: 0,
    bearing: 0,
    antialias: false, // Economiza GPU no mobile — principal causa de crash no Safari/iOS
    trackResize: true,
    fadeDuration: 150 // Evita buracos visíveis ao trocar tiles durante zoom no iPhone
  });

  console.log('[GeoMatch] Mapbox Map instanciado ✓', map);

  map.on('click', () => { if (isCinematicMode || cinematicPopup) closeCinematicPopup(); });

  map.once('load', () => {
    console.log('[GeoMatch] Mapbox map.load disparado ✓');
    window._mapIsReady = true;
    if (typeof window._onMapLoaded === 'function') {
      console.log('[GeoMatch] Chamando window._onMapLoaded()');
      window._onMapLoaded();
    }
    map.resize();
    setTimeout(() => map.resize(), 500);
    setTimeout(() => map.resize(), 900);
  });

  // Revela o mapa — dispara map:loaded para o Stimulus map-loader esconder a animação
  window._revealMap = (() => {
    let revealed = false;
    return () => {
      console.log('[GeoMatch] Tentando remover loader...');
      if (revealed) return;
      revealed = true;
      map.resize();
      const wrapper = document.querySelector('[data-controller="map-loader"]');
      if (wrapper) {
        wrapper.dispatchEvent(new CustomEvent("map:loaded"));
      } else {
        console.log('[GeoMatch] Wrapper map-loader não encontrado');
      }
    };
  })();

  // ResizeObserver: detecta mudança de tamanho do container e força redesenho do canvas
  if (mapResizeObserver) mapResizeObserver.disconnect();
  mapResizeObserver = new ResizeObserver(() => { if (map) map.resize(); });
  mapResizeObserver.observe(mapElement);

  // Intervalo de segurança: acorda o canvas a cada 500ms pelos primeiros 3s
  if (mapResizeInterval) clearInterval(mapResizeInterval);
  mapResizeInterval = setInterval(() => { if (map) map.resize(); }, 500);
  setTimeout(() => { clearInterval(mapResizeInterval); mapResizeInterval = null; }, 3000);

  // O style.load é async para poder aguardar a promise de localização.
  // window._locationPromise foi criada no turbo:load — o GPS já está rodando em paralelo
  // com o carregamento do estilo do Mapbox. Nenhuma chamada GPS duplicada aqui.
  map.on('style.load', async () => {
    map.setConfigProperty('basemap', 'lightPreset', 'day');
    // Prédios/árvores 3D apenas em zoom > 16 — poupa GPU no zoom padrão (14)
    const update3D = () => {
      const show = map.getZoom() > 16;
      map.setConfigProperty('basemap', 'show3dObjects', show);
      map.setConfigProperty('basemap', 'show3dTrees', show);
    };
    update3D();
    map.on('zoomend', update3D); // Só roda ao soltar o dedo — não bloqueia a GPU frame a frame
    map.setConfigProperty('basemap', 'showPointOfInterestLabels', false);

    // --- Aguarda resolução de localização (GPS ou banco de dados) ---
    // Se o GPS já tiver resolvido antes do style.load, o await retorna imediatamente.
    // Se o GPS ainda estiver em andamento, aguarda aqui enquanto o loader cobre o mapa.
    const coords = await window._locationPromise;

    if (coords && coords.lat && coords.lng) {
      fixedUserLat = coords.lat;
      fixedUserLng = coords.lng;
      window.presenceSetLocation?.(coords.lat, coords.lng);

      // jumpTo (sem animação): o loader ainda está visível, então não há "pulo" para o usuário.
      // flyTo causaria o salto visível porque anima desde a posição errada até a correta.
      map.jumpTo({ center: [coords.lng, coords.lat], zoom: 14 });

      console.log(`[GeoMatch] Posição definida via ${coords.source}: ${coords.lat}, ${coords.lng}`);
      updateRadarVisuals();
      loadNearbyUsers(fixedUserLat, fixedUserLng, currentRangeMeters, currentGenderFilter);
    } else {
      // Sem coordenadas válidas — informa o usuário e mantém o loader com aviso
      console.error('[GeoMatch] Sem coordenadas disponíveis.');
      const loaderCaption = document.querySelector('.map-loading__caption');
      if (loaderCaption) loaderCaption.textContent = 'Ative o GPS para usar o GeoMatch.';
    }
  });

  // Throttle via requestAnimationFrame para não recalcular turf.circle() a cada frame.
  // try/finally: se updateRadarVisuals lançar UMA exceção, rafPending ficaria travado
  // em true e o círculo pararia de seguir o mapa para sempre.
  let rafPending = false;
  map.on('move', () => {
    if (rafPending) return;
    rafPending = true;
    requestAnimationFrame(() => {
      try {
        updateRadarVisuals();
      } catch (e) {
        console.error('[GeoMatch] updateRadarVisuals falhou:', e);
      } finally {
        rafPending = false;
      }
    });
  });

  // Garante que o radar reflita o zoom final após qualquer animação terminar.
  // O handler de 'move' com rAF pode ter rodado pela última vez num zoom intermediário.
  map.on('moveend', updateRadarVisuals);
}

// --- Event Listeners e Inicialização ---

// Libera toda memória de GPU/WebGL antes do Turbo cachear ou navegar — previne crash no iOS
document.addEventListener("turbo:before-cache", () => {
  stopRotation();
  // Desregistra o handler de tempo real — a subscrição ao canal permanece viva
  // (gerenciada por presence.js) para o usuário não desaparecer do mapa de outros.
  window.setMapRealtimeHandler?.(null);
  // Limpa estado do GPS para que a próxima visita sempre inicie com rastreamento ligado
  resetTracking(document.getElementById('fab-live-tracking'));
  if (mapResizeObserver) { mapResizeObserver.disconnect(); mapResizeObserver = null; }
  if (mapResizeInterval) { clearInterval(mapResizeInterval); mapResizeInterval = null; }
  if (map) {
    map.remove();
    map = null;
    mapboxUserMarkers = {};
    mapboxMarkerDistances = {};
    mapboxUserData = {};
    fixedUserLat = null;
    fixedUserLng = null;
  }
});

// Fallback: corrige canvas ao retornar de outra aba
window.addEventListener('focus', () => { if (map && document.getElementById('map-3d')) map.resize(); });

// Garante resize ao voltar para a página via Turbo Drive (cache restaurado)
document.addEventListener("turbo:render", () => {
  if (map && document.getElementById('map-3d')) map.resize();
});

document.addEventListener("turbo:load", () => {
  console.log('[GeoMatch] turbo:load disparado - verificando se é página de mapa');
  if (typeof Turbo !== 'undefined' && Turbo.cache) Turbo.cache.clear();

  window._mapIsReady = false;
  window._onMapLoaded = null;

  const loader = document.querySelector('.map-loading');
  const mapContainer = document.getElementById('map-3d');

  console.log('[GeoMatch] mapContainer encontrado?', !!mapContainer);

  // Sem mapa nesta página: destrói loader e qualquer instância obsoleta
  if (!mapContainer) {
    if (loader) loader.remove();
    if (map) { try { map.remove(); } catch (_) {} map = null; }
    return;
  }

  // --- Reload único pós-login ---
  // Na primeira visita vinda do login, a página recarrega silenciosamente por baixo do loader.
  // O sessionStorage evita loop infinito: só recarrega UMA vez por sessão de login.
  const fromLogin = document.referrer.includes('sign_in') ||
                    document.referrer.includes('login')   ||
                    document.referrer.includes('session');
  const reloadDone = sessionStorage.getItem('geomatch_reload_done') === '1';

  if (fromLogin && !reloadDone) {
    console.log('[GeoMatch] Primeiro acesso pós-login — reload silencioso');
    sessionStorage.setItem('geomatch_reload_done', '1');
    window.location.reload();
    return; // interrompe; a página reinicia com o loader já visível
  }
  // ------------------------------

  console.log('[GeoMatch] Loader iniciado');

  // --- Prioridade 1 (GPS) + Prioridade 2 (Banco) — iniciado AGORA, antes do Mapbox ---
  //
  // Dois objetivos com uma única chamada:
  //   1. Força o popup de permissão no iOS ANTES do Mapbox instanciar (UX correto)
  //   2. Começa a resolução real de coordenadas sem duplicar requisições
  //
  // O resultado fica em window._locationPromise para ser awaited dentro de style.load.
  // A promise SEMPRE resolve (nunca rejeita) — o fallback para DB coords está no catch.
  {
    const dbLat = parseFloat(mapContainer.dataset.userLat) || null;
    const dbLng = parseFloat(mapContainer.dataset.userLng) || null;
    const hasDbCoords = dbLat && dbLng && dbLat !== 0 && dbLng !== 0;

    window._locationPromise = new Promise((resolve) => {
      if (!('geolocation' in navigator)) {
        console.log('[GeoMatch] Geolocation indisponível — usando coords do banco');
        resolve(hasDbCoords
          ? { lat: dbLat, lng: dbLng, source: 'db_no_geo' }
          : null
        );
        return;
      }

      navigator.geolocation.getCurrentPosition(
        (position) => {
          console.log('[GeoMatch] GPS resolvido ✓');
          resolve({ lat: position.coords.latitude, lng: position.coords.longitude, source: 'gps' });
        },
        (error) => {
          console.warn(`[GeoMatch] GPS falhou (código ${error.code}): ${error.message}`);
          if (error.code === 1) {
            // Permissão negada — alerta movido para cá (antes era dentro de style.load)
            alert('O GeoMatch precisa da sua localização para funcionar. Por favor, verifique as permissões do seu navegador/celular.');
          }
          resolve(hasDbCoords
            ? { lat: dbLat, lng: dbLng, source: 'db_fallback' }
            : null
          );
        },
        { enableHighAccuracy: true, maximumAge: 0, timeout: 8000 }
      );
    });
  }

  // Sincronização: revela o mapa apenas quando os TRÊS flags forem verdadeiros:
  //   timerFired   — timer mínimo de 2.5s para garantir que o Mapbox renderizou
  //   mapFired     — evento 'load' do Mapbox disparou
  //   locationFired — GPS ou DB coords foram resolvidos
  //
  // Declarados FORA do setTimeout para que o .then() da locationPromise acesse o escopo.
  let timerFired    = false;
  let mapFired      = false;
  let locationFired = false;

  const tryReveal = () => {
    if (!timerFired || !mapFired || !locationFired) return;
    console.log('[GeoMatch] Três condições OK (timer + mapa + localização) — revelando mapa');
    if (window._revealMap) window._revealMap();
    sessionStorage.removeItem('geomatch_reload_done');
  };

  // Terceiro flag: localização resolvida (GPS ou DB)
  window._locationPromise.then(() => { locationFired = true; tryReveal(); });

  // Debounce 300ms para o Turbo finalizar a transição de DOM
  setTimeout(() => {
    initializeMapAndLocation();
    requestAnimationFrame(() => { if (map) map.resize(); });

    window._onMapLoaded = () => { mapFired = true; tryReveal(); };
    setTimeout(() => { timerFired = true; tryReveal(); }, 2500);
  }, 300);

  // Registra o handler de tempo real na camada global de presença (presence.js).
  // A subscrição ao MapChannel é gerenciada globalmente — não criamos uma nova aqui.
  window.setMapRealtimeHandler?.(_handleMapRealtime);

  const rangeSlider = document.getElementById("radar-range");
  const rangeValueText = document.getElementById("range-value-text");
  const radarControl = document.querySelector('.radar-control-floating');
  const containerElement = document.querySelector('.discover-fullscreen-container');
  const fabCenterMap = document.getElementById("fab-center-map");
  const toggleVisibilityBtn = document.getElementById("toggle-visibility-btn");
  const fabLiveTracking = document.getElementById("fab-live-tracking");
  const closePopupBtn = document.getElementById("close-popup-btn");
  const popupOverlay = document.querySelector(".popup-overlay");
  const userPopup = document.getElementById("user-popup");

  // SLIDER DE RAIO
  if (rangeSlider && rangeValueText) {
    const updateSliderVisuals = (val) => {
      rangeValueText.textContent = `${val}m`;
      const max = rangeSlider.max || 300;
      const percent = (val / max) * 100;
      rangeSlider.style.backgroundImage = `linear-gradient(to right, #f4e4bc 0%, #f4e4bc ${percent}%, transparent ${percent}%, transparent 100%)`;
      updateRadarVisuals();
    };

    rangeSlider.value = currentRangeMeters;
    updateSliderVisuals(currentRangeMeters);
    
    rangeSlider.addEventListener("input", (e) => {
      const val = parseInt(e.target.value, 10);
      currentRangeMeters = val;
      updateSliderVisuals(val);
      filterMarkersByRange();
    });
    
    rangeSlider.addEventListener("change", () => {
      localStorage.setItem(STORAGE_KEYS.RANGE, currentRangeMeters);
      if (fixedUserLat && fixedUserLng) {
        loadNearbyUsers(fixedUserLat, fixedUserLng, currentRangeMeters, currentGenderFilter);
      }
    });
  }

  // Radar control é fixo — posicionado pelo CSS, sem drag JS.

  // FILTRO GÊNERO — controle segmentado (partial users/_gender_filter + Stimulus
  // gender-filter). O Stimulus dispara "gm:gender-changed" no document com a chave
  // canônica (all/male/female/non-binary); aqui limpamos os marcadores e refazemos
  // o fetch. Reset por visita: o módulo JS sobrevive a navegações Turbo, então sem
  // isto um filtro escolhido antes de sair da tela "vazaria" para a próxima entrada.
  currentGenderFilter = "all";

  // Guarda contra listener duplicado — este setup roda a cada turbo:load.
  if (window._gmGenderHandler) {
    document.removeEventListener("gm:gender-changed", window._gmGenderHandler);
  }
  window._gmGenderHandler = (event) => {
    const key = event.detail?.key || "all";
    if (key === currentGenderFilter) return;
    currentGenderFilter = key;

    const state = GENDER_STATES.find(s => s.key === key) || GENDER_STATES[0];
    showGenderHUD(state);

    // Limpa marcadores stale imediatamente — evita desalinhamento visual enquanto
    // o novo fetch não chega. O fetch cancelará qualquer request anterior.
    Object.values(mapboxUserMarkers).forEach(m => m.remove());
    mapboxUserMarkers = {};
    mapboxMarkerDistances = {};
    mapboxUserData = {};
    const _usersList = document.getElementById("users-list");
    if (_usersList) _usersList.innerHTML = '';

    if (fixedUserLat && fixedUserLng) {
      loadNearbyUsers(fixedUserLat, fixedUserLng, currentRangeMeters, currentGenderFilter);
    }
  };
  document.addEventListener("gm:gender-changed", window._gmGenderHandler);

  // BOTTOM SHEET
  const bottomSheet = document.querySelector(".users-bottom-sheet");
  const handle = document.querySelector(".bottom-sheet-handle");
  if (bottomSheet && handle) {
    let startY = 0; let startHeight = 0; let isDraggingSheet = false;
    let startVh = 0;
    const SNAP_MIN = 25; const SNAP_MAX = 85; const SNAP_THRESHOLD = 50;
    const onDragStart = (e) => {
      isDraggingSheet = true;
      bottomSheet.classList.add("dragging");
      startY = e.touches ? e.touches[0].clientY : e.clientY;
      startHeight = bottomSheet.getBoundingClientRect().height;
      startVh = (startHeight / window.innerHeight) * 100;
    };
    const onDragMove = (e) => {
      if (!isDraggingSheet) return;
      e.preventDefault();
      const currentY = e.touches ? e.touches[0].clientY : e.clientY;
      const deltaY = startY - currentY;
      let newHeight = startHeight + deltaY;
      const minH = window.innerHeight * (SNAP_MIN / 100);
      const maxH = window.innerHeight * (SNAP_MAX / 100);
      if (newHeight < minH) newHeight = minH + (newHeight - minH) * 0.2;
      if (newHeight > maxH) newHeight = maxH + (newHeight - maxH) * 0.2;
      bottomSheet.style.height = `${newHeight}px`;
    };
    const onDragEnd = () => {
      if (!isDraggingSheet) return;
      isDraggingSheet = false;
      bottomSheet.classList.remove("dragging");
      const currentHeight = bottomSheet.getBoundingClientRect().height;
      const viewportHeight = window.innerHeight;
      const currentVh = (currentHeight / viewportHeight) * 100;
      if (currentVh > 40) {
        bottomSheet.style.height = `${SNAP_MAX}vh`;
      } else {
        bottomSheet.style.height = `${SNAP_MIN}vh`;
      }
    };
    handle.addEventListener("mousedown", onDragStart);
    handle.addEventListener("touchstart", onDragStart, { passive: false });
    window.addEventListener("mousemove", onDragMove);
    window.addEventListener("touchmove", onDragMove, { passive: false });
    window.addEventListener("mouseup", onDragEnd);
    window.addEventListener("touchend", onDragEnd);
  }

  // BOTÃO CENTRALIZAR MAPA — reset para visão 2D de navegação
  if (fabCenterMap) {
    fabCenterMap.addEventListener("click", () => {
      closeCinematicPopup();
      // fixedUserLat/Lng são sempre válidos quando o mapa está visível (reveal só ocorre após coords)
      if (fixedUserLat && fixedUserLng) {
        map.flyTo({ center: [fixedUserLng, fixedUserLat], zoom: 14, pitch: 0, bearing: 0, essential: true });
      }
    });
  }

  // MODO TEMPO REAL (FOLLOW ME)
  // Callback reutilizado tanto na inicialização automática quanto no click manual
  const trackingCallback = (newLat, newLng) => {
    fixedUserLat = newLat;
    fixedUserLng = newLng;
    window.presenceSetLocation?.(newLat, newLng);
    updateRadarVisuals();
    const now = Date.now();
    if (now - lastUserFetchTime > FETCH_COOLDOWN_MS) {
      lastUserFetchTime = now;
      // /users/nearby already updates location in the DB + broadcasts; presence.js
      // handles the background heartbeat — no need to call update_location separately.
      loadNearbyUsers(newLat, newLng, currentRangeMeters, currentGenderFilter);
    }
  };

  if (fabLiveTracking) {
    fabLiveTracking.addEventListener("click", () => {
      const isNowTracking = toggleLiveTracking(map, fabLiveTracking, trackingCallback);
      const metaUserId = document.querySelector('meta[name="current-user-id"]');
      const userId = metaUserId ? metaUserId.content : null;

      if (isNowTracking) {
        showTrackingToast("✅ Visibilidade em tempo real ligada! Prepare-se para encontros espontâneos.");
        if (window.Android && userId) {
          const apiToken = document.querySelector('meta[name="api-token"]')?.content ?? '';
          window.Android.iniciarRastreioSegundoPlano(userId, apiToken);
        }
      } else {
        showTrackingToast("❌ Visibilidade em tempo real desativada. Sua localização não está mais visível.");
        if (window.Android) {
          window.Android.pararRastreioSegundoPlano();
        }
      }
    });
  }

  // MODO INVISÍVEL
  if (toggleVisibilityBtn) {
    const eyeOpen = toggleVisibilityBtn.querySelector(".eye-open");
    const eyeClosed = toggleVisibilityBtn.querySelector(".eye-closed");

    const updateVisibilityUI = (isInvisible) => {
      isUserInvisible = isInvisible;
      if (isInvisible) {
        toggleVisibilityBtn.classList.add("active");
        toggleVisibilityBtn.classList.add("invisible-mode");
        if (eyeOpen) eyeOpen.classList.add("hidden");
        if (eyeClosed) eyeClosed.classList.remove("hidden");
      } else {
        toggleVisibilityBtn.classList.remove("active");
        toggleVisibilityBtn.classList.remove("invisible-mode");
        if (eyeOpen) eyeOpen.classList.remove("hidden");
        if (eyeClosed) eyeClosed.classList.add("hidden");
      }
    };

    const userData = document.getElementById('current-user-data');
    const initialInvisible = userData ? (userData.dataset.invisible === 'true') : false;
    updateVisibilityUI(initialInvisible);

    toggleVisibilityBtn.addEventListener("click", async () => {
      try {
        const token = document.querySelector('meta[name="csrf-token"]').content;
        const response = await fetch('/users/toggle_visibility', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'X-CSRF-Token': token
          }
        });

        if (response.status === 403) {
          const data = await response.json();
          if (data.upgrade_required) {
            const modalResponse = await fetch('/plans/modal?type=invisible');
            const modalHtml = await modalResponse.text();
            const container = document.getElementById("upgrade-modal-container");
            container.innerHTML = modalHtml;
            const backdrop = container.querySelector(".upgrade-modal-backdrop");
            const fecharModalGeoMatch = () => {
              if (backdrop) {
                backdrop.style.opacity = '0';
                setTimeout(() => { container.innerHTML = ""; }, 300);
              }
            };
            container.querySelectorAll(".close-modal-btn").forEach(btn => {
              btn.onclick = (e) => { e.preventDefault(); fecharModalGeoMatch(); };
            });
            if (backdrop) {
              backdrop.onclick = (e) => { if (e.target === backdrop) fecharModalGeoMatch(); };
            }
          }
          return;
        }

        if (!response.ok) throw new Error("Erro ao salvar no servidor");
        const data = await response.json();
        updateVisibilityUI(data.invisible);
      } catch (error) {
        console.error("Erro ao alternar visibilidade:", error);
      }
    });
  }

  // FECHAR POPUP APÓS AÇÃO
  document.addEventListener("turbo:submit-end", (e) => {
    const formId = e.target.id;
    if (formId === "popup-like-form" || formId === "popup-reject-form") {
      if (e.detail.success) { closeUserPopup(); }
    }
  });

  if (closePopupBtn) {
    const newBtn = closePopupBtn.cloneNode(true);
    closePopupBtn.parentNode.replaceChild(newBtn, closePopupBtn);
    newBtn.addEventListener("click", (e) => {
      e.preventDefault();
      closeUserPopup();
    });
  }

  if (popupOverlay) {
    popupOverlay.addEventListener("click", (e) => { closeUserPopup(); });
  }

  // DRAG / SWIPE NO POPUP
  const popupContent = document.querySelector(".popup-content-fullscreen");
  const popupHandle = document.querySelector(".popup-drag-handle-area");
  
  if (popupContent) {
      let startY = 0;
      let currentY = 0;
      let isDragging = false;
      let startHeight = 0;
      const THRESHOLD = 100;

      const isExpanded = () => popupContent.classList.contains("expanded");

      const onTouchStart = (e) => {
          const detailsContainer = document.getElementById("popup-full-details");
          const scrollTop = detailsContainer ? detailsContainer.scrollTop : 0;
          if (isExpanded() && scrollTop > 0 && !popupHandle.contains(e.target)) { return; }
          isDragging = true;
          startY = e.touches[0].clientY;
          startHeight = popupContent.offsetHeight;
          popupContent.style.transition = "none";
      };

      const onTouchMove = (e) => {
          if (!isDragging) return;
          currentY = e.touches[0].clientY;
          const deltaY = startY - currentY; 
          if (!isExpanded() && deltaY > 0) {
               e.preventDefault();
               popupContent.style.height = `${startHeight + deltaY}px`;
          } 
          else if (isExpanded() && deltaY < 0) {
               const detailsContainer = document.getElementById("popup-full-details");
               if (!detailsContainer || detailsContainer.scrollTop <= 0) {
                   e.preventDefault();
                   popupContent.style.height = `${startHeight + deltaY}px`;
               }
          }
      };

      const onTouchEnd = (e) => {
          if (!isDragging) return;
          isDragging = false;
          popupContent.style.transition = "height 0.3s cubic-bezier(0.25, 1, 0.5, 1)";
          popupContent.style.height = ""; 
          const deltaY = startY - currentY;
          if (!isExpanded()) {
              if (deltaY > THRESHOLD) { popupContent.classList.add("expanded"); }
          } else {
              if (deltaY < -THRESHOLD) { popupContent.classList.remove("expanded"); }
          }
      };

      popupContent.addEventListener("touchstart", onTouchStart, { passive: false });
      popupContent.addEventListener("touchmove", onTouchMove, { passive: false });
      popupContent.addEventListener("touchend", onTouchEnd);
  }

  // Liga rastreamento automaticamente ao abrir o mapa — sempre ligado por padrão,
  // sem depender do estado anterior da sessão ou de qualquer storage.
  setTimeout(() => {
    if (fabLiveTracking) {
      const metaUserId = document.querySelector('meta[name="current-user-id"]');
      const userId = metaUserId ? metaUserId.content : null;
      startLiveTracking(map, fabLiveTracking, trackingCallback);
      showTrackingToast("✅ Visibilidade em tempo real ligada! Prepare-se para encontros espontâneos.");
      if (window.Android && userId) {
        const apiToken = document.querySelector('meta[name="api-token"]')?.content ?? '';
        window.Android.iniciarRastreioSegundoPlano(userId, apiToken);
      }
    }
  }, 1000);

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") return;
    if (!("geolocation" in navigator)) return;
    navigator.geolocation.getCurrentPosition(
      (position) => {
        fixedUserLat = position.coords.latitude;
        fixedUserLng = position.coords.longitude;
        window.presenceSetLocation?.(fixedUserLat, fixedUserLng);
        updateRadarVisuals();
        const now = Date.now();
        if (now - lastUserFetchTime > FETCH_COOLDOWN_MS) {
          lastUserFetchTime = now;
          loadNearbyUsers(fixedUserLat, fixedUserLng, currentRangeMeters, currentGenderFilter);
        }
      },
      (error) => { console.warn("⚠️ Localização após desbloqueio:", error.message); },
      // maximumAge: 30000 → aceita posição de até 30s atrás.
      // Evita falha imediata enquanto o GPS aquece após desbloqueio do ecrã.
      // timeout: 15000 → aguarda até 15s por um fix fresco antes de usar posição em cache.
      { enableHighAccuracy: true, maximumAge: 30000, timeout: 15000 }
    );
  });

  const style = document.createElement("style");
  style.textContent = `
    .user-location-marker { position: relative; width: 40px; height: 40px; }
    .user-location-dot { width: 12px; height: 12px; background: #ccc099; border-radius: 50%; border: 2px solid #fff; position: relative; z-index: 10; top: 14px; left: 14px; }
    .user-location-pulse { position: absolute; width: 40px; height: 40px; border-radius: 50%; border: 3px solid rgba(212, 175, 55, 0.85); animation: pulse 0.9s ease-out infinite; }
    @keyframes pulse { 0% { transform: scale(0.6); opacity: 1; } 100% { transform: scale(1.35); opacity: 0; } }
    .loading-skeleton { display: flex; gap: 10px; padding: 10px; background: #252527; border-radius: 8px; margin-bottom: 5px; }
    .skeleton-avatar { width: 40px; height: 40px; background: #444; border-radius: 50%; }
    .skeleton-text { flex: 1; display: flex; flex-direction: column; gap: 5px; justify-content: center; }
    .skeleton-line { height: 10px; background: #444; border-radius: 4px; width: 80%; }
    .users-bottom-sheet { transition: height 0.4s cubic-bezier(0.25, 1, 0.5, 1); will-change: height; }
    .users-bottom-sheet.dragging { transition: none; }
    .premium-marker { width: 46px; height: 46px; border-radius: 50%; border: 3px solid #22c55e; box-shadow: 0 0 0 0 rgba(34,197,94,0.5), 0 4px 15px rgba(0,0,0,0.15); overflow: hidden; cursor: pointer; pointer-events: auto; position: relative; z-index: 10; transition: opacity 0.25s ease; will-change: transform; animation: markerPulse 2s ease-out infinite; }
    .premium-marker:hover { transform: scale(1.1); animation-play-state: paused; }
    .premium-marker-img { width: 100%; height: 100%; object-fit: cover; display: block; pointer-events: none; }
    @keyframes markerPulse { 0% { box-shadow: 0 0 0 0 rgba(34,197,94,0.6), 0 4px 15px rgba(0,0,0,0.15); } 70% { box-shadow: 0 0 0 12px rgba(34,197,94,0), 0 4px 15px rgba(0,0,0,0.15); } 100% { box-shadow: 0 0 0 0 rgba(34,197,94,0), 0 4px 15px rgba(0,0,0,0.15); } }
    .mapboxgl-marker { pointer-events: auto !important; }
    body.cinematic-mode .premium-marker { box-shadow: none !important; animation-play-state: paused !important; border-color: rgba(34,197,94,0.4) !important; }
    #mco-view-btn:active { transform: scale(0.95); }
  `;
  d
  ocument.head.appendChild(style);
});