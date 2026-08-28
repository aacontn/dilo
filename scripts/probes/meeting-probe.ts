// Probe de diarización de reuniones: interactions API con audio de 2 hablantes.
import { readFileSync, writeFileSync } from "fs";

const STORE = `${process.env.HOME}/Library/Application Support/cl.espaciodigital.dilo/settings_store.json`;
const key = JSON.parse(readFileSync(STORE, "utf8")).settings
  .post_process_api_keys.google;

// Unir s1+s2+s3 con 400 ms de silencio entre turnos, en un WAV 16k mono válido.
const pcmOf = (f: string) => {
  const b = readFileSync(`${import.meta.dir}/${f}`);
  return b.subarray(b.indexOf("data") + 8);
};
const gap = Buffer.alloc(16000 * 0.4 * 2); // 400 ms
const pcm = Buffer.concat([
  pcmOf("s1.wav"),
  gap,
  pcmOf("s2.wav"),
  gap,
  pcmOf("s3.wav"),
]);
const header = Buffer.alloc(44);
header.write("RIFF", 0);
header.writeUInt32LE(36 + pcm.length, 4);
header.write("WAVE", 8);
header.write("fmt ", 12);
header.writeUInt32LE(16, 16);
header.writeUInt16LE(1, 20);
header.writeUInt16LE(1, 22);
header.writeUInt32LE(16000, 24);
header.writeUInt32LE(32000, 28);
header.writeUInt16LE(2, 32);
header.writeUInt16LE(16, 34);
header.write("data", 36);
header.writeUInt32LE(pcm.length, 40);
const wav = Buffer.concat([header, pcm]);
writeFileSync(`${import.meta.dir}/reunion.wav`, wav);
console.log(`Reunión sintética: ${(pcm.length / 32000).toFixed(1)}s`);

async function probe(label: string, config: Record<string, unknown> | null) {
  const t0 = performance.now();
  const body: any = {
    model: "gemini-3.5-transcribe",
    input: [
      { type: "audio", mime_type: "audio/wav", data: wav.toString("base64") },
    ],
  };
  if (config) body.generation_config = { transcription_config: config };
  const res = await fetch(
    "https://generativelanguage.googleapis.com/v1beta/interactions",
    {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": key },
      body: JSON.stringify(body),
    },
  );
  const secs = ((performance.now() - t0) / 1000).toFixed(2);
  const json: any = await res.json().catch(() => null);
  console.log(`\n=== ${label} — HTTP ${res.status} en ${secs}s ===`);
  if (!res.ok || !json) {
    console.log(JSON.stringify(json)?.slice(0, 400));
    return;
  }
  // Mostrar la estructura completa de steps (recortada) para ver el shape real
  // de hablantes/timestamps, no solo el texto plano.
  console.log(JSON.stringify(json.steps, null, 1)?.slice(0, 2500));
}

await probe("smart + diarization", { mode: "smart", diarization: true });
await probe("verbatim + diarization + word_timestamps", {
  diarization: true,
  word_timestamps: true,
});
console.log("\nProbe reuniones terminado.");
