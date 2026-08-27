import { readFileSync } from "fs";
const STORE = `${process.env.HOME}/Library/Application Support/cl.espaciodigital.dilo/settings_store.json`;
const key = JSON.parse(readFileSync(STORE, "utf8")).settings.post_process_api_keys.google;
const wav = readFileSync(`${import.meta.dir}/reunion.wav`);
const t0 = performance.now();
const res = await fetch("https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-transcribe:generateContent", {
  method: "POST",
  headers: { "Content-Type": "application/json", "x-goog-api-key": key },
  body: JSON.stringify({
    contents: [{ role: "user", parts: [{ inline_data: { mime_type: "audio/wav", data: wav.toString("base64") } }] }],
    generationConfig: { temperature: 0, audioTranscriptionConfig: { wordTimestamp: true, diarization: true } },
  }),
});
console.log(`HTTP ${res.status} en ${((performance.now() - t0) / 1000).toFixed(2)}s`);
const json: any = await res.json().catch(() => null);
console.log(JSON.stringify(json, null, 1)?.slice(0, 3000));
