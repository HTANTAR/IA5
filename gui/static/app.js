const chat = document.getElementById("chat");
const form = document.getElementById("form");
const input = document.getElementById("input");
const resetBtn = document.getElementById("resetBtn");
const voiceBtn = document.getElementById("voiceBtn");
const micBtn = document.getElementById("micBtn");
const wakeBtn = document.getElementById("wakeBtn");
const proposalsBtn = document.getElementById("proposalsBtn");
const closeProposalsBtn = document.getElementById("closeProposalsBtn");
const proposalsPanel = document.getElementById("proposalsPanel");
const proposalsList = document.getElementById("proposalsList");
const avatarWrap = document.getElementById("avatarWrap");
const stateLabel = document.getElementById("stateLabel");
const mouth = document.getElementById("mouth");

const AGENT_LABELS = {
  codigo: "Agente de código",
  texto: "Agente de texto",
  navegador: "Agente de navegador",
  aprender: "Agente de aprendizaje",
  crear_agente: "Meta-agente (sandbox)",
  general: "IA Local",
};

let voiceEnabled = true;
let isRecording = false;
let audioCtx = null;
let wakeListening = false;
let wakeEventSource = null;

function setAvatarState(state, label) {
  avatarWrap.classList.remove("listening", "speaking", "thinking");
  if (state) avatarWrap.classList.add(state);
  stateLabel.textContent = label;
}

function addMessage(role, text, agent) {
  const div = document.createElement("div");
  div.className = `msg ${role}`;
  if (role === "bot" && agent) {
    const tag = document.createElement("div");
    tag.className = "tag";
    tag.textContent = AGENT_LABELS[agent] || agent;
    div.appendChild(tag);
  }
  const body = document.createElement("div");
  body.textContent = text;
  div.appendChild(body);
  chat.appendChild(div);
  chat.scrollTop = chat.scrollHeight;
  return div;
}

async function speakReply(text) {
  if (!voiceEnabled || !text.trim()) return;
  try {
    const res = await fetch("/api/tts", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
    const blob = await res.blob();
    if (blob.size === 0) return;
    const url = URL.createObjectURL(blob);
    const audio = new Audio(url);

    if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    const source = audioCtx.createMediaElementSource(audio);
    const analyser = audioCtx.createAnalyser();
    analyser.fftSize = 256;
    source.connect(analyser);
    analyser.connect(audioCtx.destination);
    const data = new Uint8Array(analyser.frequencyBinCount);

    setAvatarState("speaking", "hablando");

    function animateMouth() {
      analyser.getByteFrequencyData(data);
      const avg = data.reduce((a, b) => a + b, 0) / data.length;
      const ry = 2.5 + Math.min(avg / 8, 14);
      mouth.setAttribute("ry", ry.toFixed(1));
      if (!audio.paused && !audio.ended) requestAnimationFrame(animateMouth);
    }

    audio.addEventListener("play", () => requestAnimationFrame(animateMouth));
    audio.addEventListener("ended", () => {
      mouth.setAttribute("ry", "2.5");
      restAvatarState();
      URL.revokeObjectURL(url);
    });
    await audio.play();
  } catch (err) {
    restAvatarState();
  }
}

function restAvatarState() {
  if (wakeListening) {
    setAvatarState("listening", "escucha permanente");
  } else {
    setAvatarState(null, "en línea");
  }
}

async function showBotReply(agent, text) {
  addMessage("bot", text, agent);
  await speakReply(text);
  if (!voiceEnabled) restAvatarState();
}

async function sendMessage(message) {
  if (!message.trim()) return;
  addMessage("user", message);

  const thinking = addMessage("bot", "Pensando...", null);
  thinking.classList.add("thinking");
  setAvatarState("thinking", "pensando");

  try {
    const res = await fetch("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message }),
    });
    const data = await res.json();
    thinking.remove();
    await showBotReply(data.agent, data.reply);
  } catch (err) {
    thinking.remove();
    addMessage("bot", "Error de conexión con el backend local.", null);
    setAvatarState(null, "en línea");
  }
}

form.addEventListener("submit", (e) => {
  e.preventDefault();
  const message = input.value.trim();
  if (!message) return;
  input.value = "";
  sendMessage(message);
});

resetBtn.addEventListener("click", async () => {
  await fetch("/api/reset", { method: "POST" });
  chat.innerHTML = "";
});

async function refreshVoiceLabel() {
  try {
    const res = await fetch("/api/voice");
    const data = await res.json();
    voiceEnabled = data.enabled;
    voiceBtn.textContent = voiceEnabled ? "🔊 Voz: activada" : "🔇 Voz: desactivada";
  } catch (err) {
    // silencioso, no rompe la UI si falla
  }
}

voiceBtn.addEventListener("click", async () => {
  const res = await fetch("/api/voice", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ enabled: !voiceEnabled }),
  });
  const data = await res.json();
  voiceEnabled = data.enabled;
  voiceBtn.textContent = voiceEnabled ? "🔊 Voz: activada" : "🔇 Voz: desactivada";
});

micBtn.addEventListener("click", async () => {
  if (isRecording) {
    isRecording = false;
    micBtn.classList.remove("recording");
    micBtn.textContent = "🎤 Hablar";
    micBtn.disabled = true;
    setAvatarState("thinking", "transcribiendo");
    try {
      const res = await fetch("/api/listen/stop", { method: "POST" });
      const data = await res.json();
      micBtn.disabled = false;
      if (data.text && data.text.trim()) {
        sendMessage(data.text.trim());
      } else {
        setAvatarState(null, "en línea");
      }
    } catch (err) {
      micBtn.disabled = false;
      setAvatarState(null, "en línea");
    }
  } else {
    try {
      await fetch("/api/listen/start", { method: "POST" });
      isRecording = true;
      micBtn.classList.add("recording");
      micBtn.textContent = "⏹ Escuchando... (click para enviar)";
      setAvatarState("listening", "escuchando");
    } catch (err) {
      setAvatarState(null, "en línea");
    }
  }
});

function connectWakeStream() {
  if (wakeEventSource) return;
  wakeEventSource = new EventSource("/api/wake/stream");
  wakeEventSource.onmessage = (event) => {
    const data = JSON.parse(event.data);
    if (data.type === "user") {
      addMessage("user", data.text);
      setAvatarState("thinking", "pensando");
    } else if (data.type === "assistant") {
      showBotReply(data.agent, data.text);
    }
  };
}

wakeBtn.addEventListener("click", async () => {
  if (wakeListening) {
    await fetch("/api/wake/stop", { method: "POST" });
    wakeListening = false;
    if (wakeEventSource) {
      wakeEventSource.close();
      wakeEventSource = null;
    }
    wakeBtn.classList.remove("active");
    wakeBtn.textContent = "👂 Escucha permanente";
    micBtn.disabled = false;
    setAvatarState(null, "en línea");
  } else {
    const res = await fetch("/api/wake/start", { method: "POST" });
    const data = await res.json();
    wakeListening = data.listening;
    wakeBtn.classList.add("active");
    wakeBtn.textContent = "👂 Escuchando (activa con \"Esclava\")";
    micBtn.disabled = true;
    setAvatarState("listening", "escucha permanente");
    connectWakeStream();
  }
});

async function loadProposals() {
  proposalsList.textContent = "Cargando...";
  try {
    const res = await fetch("/api/proposals");
    const data = await res.json();
    if (!data.proposals.length) {
      proposalsList.textContent = "No hay propuestas todavía. Pedile \"creá un agente para...\" para generar una.";
      return;
    }
    proposalsList.innerHTML = "";
    for (const p of data.proposals) {
      const div = document.createElement("div");
      div.className = "proposal-item";
      const statusClass = p.test_passed ? "pass" : "fail";
      const statusText = p.test_passed ? "✓ pasó la prueba básica" : "✗ tiene errores";
      div.innerHTML = `
        <div class="req">${p.request}</div>
        <div class="desc">${p.description || ""}</div>
        <div class="status ${statusClass}">${statusText}</div>
        <div class="folder">sandbox/pending_review/${p.folder}/</div>
      `;
      proposalsList.appendChild(div);
    }
  } catch (err) {
    proposalsList.textContent = "Error cargando propuestas.";
  }
}

proposalsBtn.addEventListener("click", () => {
  proposalsPanel.classList.toggle("hidden");
  if (!proposalsPanel.classList.contains("hidden")) loadProposals();
});

closeProposalsBtn.addEventListener("click", () => {
  proposalsPanel.classList.add("hidden");
});

refreshVoiceLabel();
