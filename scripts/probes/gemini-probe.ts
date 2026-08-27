// Probe de Gemini 3.5 Transcribe para Dilo — live (WebSocket) y batch (interactions).
// La key se lee del settings store de Dilo y jamás se imprime.
import { spawnSync } from "child_process";
import { readFileSync } from "fs";

const STORE = `${process.env.HOME}/Library/Application Support/cl.espaciodigital.dilo/settings_store.json`;
const WAV = `${import.meta.dir}/dictado.wav`;
const ENDPOINT = "https://generativelanguage.googleapis.com";
const WS_URL =
  "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";

const key = JSON.parse(readFileSync(STORE, "utf8")).settings.post_process_api_keys.google;
if (!key) {
  console.error("Sin key bajo post_process_api_keys.google");
  process.exit(1);
}

// PCM crudo: saltar hasta el chunk "data" del WAV.
const wav = readFileSync(WAV);
const dataIdx = wav.indexOf("data");
const pcm = wav.subarray(dataIdx + 8);
const audioSecs = pcm.length / 2 / 16000;
console.log(`Audio: ${audioSecs.toFixed(1)}s, ${pcm.length} bytes PCM`);

const now = () => performance.now();

// ---------- LIVE ----------
async function probeLive(mode: "SMART" | "VERBATIM") {
  console.log(`\n=== LIVE ${mode} (gemini-3.5-transcribe-live) ===`);
  const t0 = now();
  const events: string[] = [];
  let firstPartialAt: number | null = null;
  let lastPartial = "";
  let finalText = "";
  let audioDoneAt: number | null = null;
  let resolveDone!: () => void;
  const done = new Promise<void>((r) => (resolveDone = r));

  const ws = new WebSocket(WS_URL, { headers: { "x-goog-api-key": key } } as any);
  ws.binaryType = "arraybuffer";

  const send = (obj: unknown) => ws.send(JSON.stringify(obj));
  const stamp = (s: string) => events.push(`t+${((now() - t0) / 1000).toFixed(2)}s  ${s}`);

  const timeout = setTimeout(() => {
    stamp("TIMEOUT global (45s)");
    try { ws.close(); } catch {}
    resolveDone();
  }, 45_000);

  ws.onopen = () => {
    stamp("WS abierto");
    send({
      setup: {
        model: "models/gemini-3.5-transcribe-live",
        generationConfig: { responseModalities: ["TEXT"] },
        inputAudioTranscription: { mode },
        realtimeInputConfig: { automaticActivityDetection: { disabled: true } },
      },
    });
  };
  ws.onerror = (e: any) => { stamp(`WS error: ${e?.message ?? e}`); };
  ws.onclose = (e: any) => {
    stamp(`WS cerrado (${e.code} ${e.reason || ""})`);
    clearTimeout(timeout);
    resolveDone();
  };
  ws.onmessage = async (ev: MessageEvent) => {
    const raw = typeof ev.data === "string" ? ev.data : Buffer.from(ev.data as ArrayBuffer).toString("utf8");
    let msg: any;
    try { msg = JSON.parse(raw); } catch { stamp(`frame no-JSON (${raw.length}b)`); return; }
    if (msg.setupComplete !== undefined || msg.setup_complete !== undefined) {
      stamp("setupComplete");
      streamAudio();
      return;
    }
    if (msg.error) { stamp(`ERROR servidor: ${JSON.stringify(msg.error).slice(0, 300)}`); return; }
    const content = msg.serverContent ?? msg.server_content;
    const interim = content?.interimInputTranscription ?? content?.interim_input_transcription;
    const finalN = content?.inputTranscription ?? content?.input_transcription;
    if (interim?.text) {
      if (firstPartialAt === null) { firstPartialAt = now() - t0; stamp(`PRIMER PARCIAL: "${interim.text.slice(0, 60)}"`); }
      lastPartial = interim.text;
      return;
    }
    if (finalN?.text) {
      finalText += finalN.text;
      stamp(`FINAL(+${finalN.text.length}ch): "${finalN.text.slice(0, 80)}"`);
      return;
    }
    if (content?.goAway !== undefined || msg.goAway !== undefined) { stamp("goAway"); return; }
    stamp(`frame ignorado: ${Object.keys(msg).join(",")}`);
  };

  async function streamAudio() {
    send({ realtimeInput: { activityStart: {} } });
    const CHUNK = 3200; // 100 ms de PCM16 a 16 kHz
    for (let off = 0; off < pcm.length; off += CHUNK) {
      const chunk = pcm.subarray(off, off + CHUNK);
      send({ realtimeInput: { audio: { data: chunk.toString("base64"), mimeType: "audio/pcm;rate=16000" } } });
      await new Promise((r) => setTimeout(r, 100)); // ritmo tiempo-real
    }
    send({ realtimeInput: { activityEnd: {} } });
    audioDoneAt = now() - t0;
    stamp("audio completo enviado (activityEnd)");
    // dar 12 s para el final y cerrar
    setTimeout(() => { try { ws.close(); } catch {} }, 12_000);
  }

  await done;
  console.log(events.join("\n"));
  console.log(`\n→ primer parcial: ${firstPartialAt ? (firstPartialAt / 1000).toFixed(2) + "s desde t0" : "NUNCA"}`);
  if (audioDoneAt !== null) {
    console.log(`→ fin de audio: t+${(audioDoneAt / 1000).toFixed(2)}s`);
  }
  console.log(`→ último parcial: "${lastPartial}"`);
  console.log(`→ TEXTO FINAL: "${finalText}"`);
  return { firstPartialAt, finalText, audioDoneAt };
}

// ---------- BATCH ----------
async function probeBatch(mime: string, body: Buffer, label: string) {
  console.log(`\n=== BATCH interactions smart (${label}) ===`);
  const t0 = now();
  const res = await fetch(`${ENDPOINT}/v1beta/interactions`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-goog-api-key": key },
    body: JSON.stringify({
      model: "gemini-3.5-transcribe",
      input: [{ type: "audio", mime_type: mime, data: body.toString("base64") }],
      generation_config: { transcription_config: { mode: "smart" } },
    }),
  });
  const secs = ((now() - t0) / 1000).toFixed(2);
  const json: any = await res.json().catch(() => null);
  if (!res.ok || !json) {
    console.log(`HTTP ${res.status} en ${secs}s — ${JSON.stringify(json)?.slice(0, 300)}`);
    return;
  }
  const text = (json.steps ?? [])
    .filter((s: any) => s.type === "model_output")
    .flatMap((s: any) => s.content ?? [])
    .filter((c: any) => c.type === "text")
    .map((c: any) => c.text)
    .join("");
  console.log(`HTTP 200 en ${secs}s, status=${json.status}`);
  console.log(`→ TEXTO: "${text}"`);
}

await probeLive("SMART");
await probeBatch("audio/wav", wav, "WAV directo, sin FLAC");
console.log("\nProbe terminado.");
