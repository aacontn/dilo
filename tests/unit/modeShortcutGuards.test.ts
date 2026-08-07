import { describe, expect, test } from "bun:test";

/**
 * Los tres guards que cierra la revisión final de "un atajo por modo". La
 * lógica de cada uno vive en una función pura ya probada aparte
 * (`mode_shortcut_is_blocked`, `resolve_post_process_target` y
 * `modeDeleteBlock`); lo que estas pruebas fijan es el **cableado**, que es
 * justo lo que las mutaciones al sitio de la llamada pasaban por alto: una
 * función correcta que nadie llama no protege a nadie.
 *
 * Se verifica sobre el texto del archivo, igual que `appShell.test.ts`: montar
 * los componentes pediría React Testing Library, una dependencia nueva.
 */

describe("Transformar apagado bloquea las teclas de modo", () => {
  test("el atajo de modo consulta post_process_enabled antes de grabar", async () => {
    const source = await Bun.file("src-tauri/src/actions.rs").text();
    expect(source).toContain(
      "mode_shortcut_is_blocked(binding_id, get_settings(app).post_process_enabled)",
    );
    // Y avisa, en vez de dejar la tecla muda: mismo criterio que el guard del
    // asistente hablado, justo arriba.
    expect(source).toContain('error_type: "post_process_disabled".to_string()');
  });

  test("la interfaz explica por qué la tecla no hizo nada", async () => {
    const source = await Bun.file("src/hooks/useRecordingErrorToast.ts").text();
    expect(source).toContain('error_type === "post_process_disabled"');
    expect(source).toContain("errors.postProcessDisabledTitle");
  });
});

describe("--toggle-post-process y SIGUSR1 aplican un modo", () => {
  test("el flag de CLI acepta un modo y va por send_post_process_input", async () => {
    const source = await Bun.file("src-tauri/src/lib.rs").text();
    expect(source).toContain('a.strip_prefix("--toggle-post-process=")');
    expect(source).toContain(
      'signal_handle::send_post_process_input(app, mode, "CLI")',
    );
    // El binding retirado ya no se dispara desde acá: sin modo activo pegaba
    // el dictado crudo, que es el bug que esta versión vino a matar.
    expect(source).not.toContain(
      'send_transcription_input(app, "transcribe_with_post_process"',
    );
  });

  test("SIGUSR1 resuelve un modo en vez del atajo general retirado", async () => {
    const source = await Bun.file("src-tauri/src/signal_handle.rs").text();
    expect(source).toContain(
      'send_post_process_input(&app_handle, "", "SIGUSR1")',
    );
    expect(source).toContain('format!("mode:{id}")');
  });

  test("la bandera está documentada como lo que hace ahora", async () => {
    const source = await Bun.file("CLAUDE.md").text();
    expect(source).toContain("--toggle-post-process[=<mode>]");
    expect(source).toContain("resolve_post_process_target");
  });
});

describe('"Eliminar" no promete borrar un modo de fábrica', () => {
  test("el botón se deshabilita con modeDeleteBlock y explica el motivo", async () => {
    const source = await Bun.file(
      "src/components/settings/post-processing/PostProcessingSettings.tsx",
    ).text();
    expect(source).toContain("modeDeleteBlock(prompts, selectedPrompt.id)");
    expect(source).toContain("disabled={deleteBlock !== null}");
    expect(source).toContain('deleteBlock === "factory-preset"');
    expect(source).toContain(
      "settings.postProcessing.prompts.presetCannotBeDeleted",
    );
  });
});
