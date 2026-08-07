use crate::settings::LLMPrompt;
use crate::TranscriptionCoordinator;
#[cfg(unix)]
use log::debug;
use log::warn;
use tauri::{AppHandle, Manager};

#[cfg(unix)]
use signal_hook::consts::{SIGUSR1, SIGUSR2};
#[cfg(unix)]
use signal_hook::iterator::Signals;
#[cfg(unix)]
use std::thread;

/// Send a transcription input to the coordinator.
/// Used by signal handlers, CLI flags, and any other external trigger.
pub fn send_transcription_input(app: &AppHandle, binding_id: &str, source: &str) {
    if let Some(c) = app.try_state::<TranscriptionCoordinator>() {
        c.send_input(binding_id, source, true, false);
    } else {
        warn!("TranscriptionCoordinator not initialized");
    }
}

/// Por qué `--toggle-post-process` / `SIGUSR1` no pudieron elegir un modo.
#[derive(Debug, PartialEq, Eq)]
pub enum PostProcessTargetError {
    /// Se pidió un modo por id o nombre y no existe ninguno así.
    ModeNotFound(String),
    /// No se pidió ninguno y no hay ningún modo con tecla asignada.
    NoModeWithShortcut,
}

/// Qué modo aplica un disparo externo (`--toggle-post-process`, `SIGUSR1`).
///
/// Hasta la 0.2.2 estas dos entradas disparaban el binding
/// `transcribe_with_post_process`, que aplicaba el "modo activo". Ese concepto
/// ya no existe: el modo sale del atajo que disparó el dictado. Sin traducción,
/// las dos quedaron **pegando dictado crudo** —un sinónimo exacto de
/// `--toggle-transcription`, con la promesa de transformar incumplida—, así que
/// acá se resuelve a un `mode:<id>` real, el mismo contrato que usa el teclado.
///
/// - Con valor (`--toggle-post-process=dilo-code`): se busca por id exacto y,
///   si no, por nombre sin distinguir mayúsculas — el nombre es lo que la
///   persona ve en pantalla, y los modos propios no tienen un id legible.
/// - Sin valor (y `SIGUSR1`, que no puede llevar argumentos): el **primer modo
///   con tecla asignada**, en el orden en que están guardados. O sea "lo que
///   hace mi tecla de transformar": en una instalación de fábrica es Limpio, y
///   en una migrada es el modo que heredó la tecla del atajo general.
/// - Si no hay ninguno, es un error explícito: mejor no grabar que grabar
///   prometiendo una transformación que no va a pasar.
///
/// Ojo: un modo pedido por id **no** necesita tener tecla. Pedirlo por nombre
/// ya es tan explícito como apretar una.
pub fn resolve_post_process_target(
    prompts: &[LLMPrompt],
    requested: &str,
) -> Result<String, PostProcessTargetError> {
    let requested = requested.trim();
    if requested.is_empty() {
        return prompts
            .iter()
            .find(|prompt| {
                prompt
                    .shortcut
                    .as_deref()
                    .is_some_and(|shortcut| !shortcut.trim().is_empty())
            })
            .map(|prompt| prompt.id.clone())
            .ok_or(PostProcessTargetError::NoModeWithShortcut);
    }

    // `to_lowercase` y no `eq_ignore_ascii_case`: los nombres de fábrica son
    // español ("Código"), y el plegado ASCII deja la `Ó` afuera.
    let requested_lower = requested.to_lowercase();
    prompts
        .iter()
        .find(|prompt| prompt.id == requested)
        .or_else(|| {
            prompts
                .iter()
                .find(|prompt| prompt.name.trim().to_lowercase() == requested_lower)
        })
        .map(|prompt| prompt.id.clone())
        .ok_or_else(|| PostProcessTargetError::ModeNotFound(requested.to_string()))
}

/// Dispara un dictado con transformación desde fuera del teclado
/// (`--toggle-post-process`, `SIGUSR1`). `requested_mode` vacío = sin modo
/// pedido; ver [`resolve_post_process_target`].
///
/// El aviso de que no se pudo elegir modo va sólo al log: las dos entradas son
/// de script o terminal, y la segunda instancia que reenvía el flag ya salió
/// cuando esto corre. Si el modo sí resuelve, el resto del camino es idéntico
/// al de la tecla, incluido el guard de "Transformar" apagado
/// (`actions::mode_shortcut_is_blocked`), que sí avisa en pantalla.
pub fn send_post_process_input(app: &AppHandle, requested_mode: &str, source: &str) {
    let prompts = crate::settings::get_settings(app).post_process_prompts;
    match resolve_post_process_target(&prompts, requested_mode) {
        Ok(id) => send_transcription_input(app, &format!("mode:{id}"), source),
        Err(PostProcessTargetError::ModeNotFound(requested)) => {
            warn!(
                "{source}: no existe ningún modo '{requested}'; no se graba nada. Los modos disponibles son: {}",
                prompts
                    .iter()
                    .map(|prompt| format!("{} ({})", prompt.id, prompt.name))
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        }
        Err(PostProcessTargetError::NoModeWithShortcut) => {
            warn!(
                "{source}: ningún modo tiene tecla asignada, así que no hay cuál aplicar. Asigna una en Ajustes › Transformar o pide el modo por su nombre (--toggle-post-process=Correo)."
            );
        }
    }
}

#[cfg(unix)]
pub fn setup_signal_handler(app_handle: AppHandle, mut signals: Signals) {
    debug!("Signal handlers registered (SIGUSR1, SIGUSR2)");
    thread::spawn(move || {
        for sig in signals.forever() {
            match sig {
                SIGUSR1 => {
                    debug!("Received SIGUSR1");
                    // Una señal no lleva argumentos: se aplica el modo de la
                    // tecla de transformar (ver `resolve_post_process_target`).
                    send_post_process_input(&app_handle, "", "SIGUSR1");
                }
                SIGUSR2 => {
                    debug!("Received SIGUSR2");
                    send_transcription_input(&app_handle, "transcribe", "SIGUSR2");
                }
                _ => continue,
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::{resolve_post_process_target, PostProcessTargetError};
    use crate::settings::LLMPrompt;

    fn prompt(id: &str, name: &str, shortcut: Option<&str>) -> LLMPrompt {
        LLMPrompt {
            id: id.to_string(),
            name: name.to_string(),
            prompt: String::new(),
            shortcut: shortcut.map(str::to_string),
            provider_id: None,
            model: None,
        }
    }

    fn prompts() -> Vec<LLMPrompt> {
        vec![
            prompt("dilo-clean", "Limpio", None),
            prompt("dilo-email", "Correo", Some("fn+f17")),
            prompt("dilo-code", "Código", Some("fn+f18")),
        ]
    }

    #[test]
    fn sin_valor_se_usa_el_primer_modo_con_tecla() {
        // Lo que hace la tecla de transformar de esta instalación. Antes esta
        // entrada disparaba el atajo general retirado y pegaba dictado crudo.
        assert_eq!(
            resolve_post_process_target(&prompts(), ""),
            Ok("dilo-email".to_string())
        );
    }

    #[test]
    fn sin_ningun_modo_con_tecla_es_un_error_explicito() {
        // Grabar acá sería repetir el bug: prometer transformación y pegar el
        // dictado sin tocar.
        let sin_teclas = vec![prompt("dilo-clean", "Limpio", Some("   "))];
        assert_eq!(
            resolve_post_process_target(&sin_teclas, ""),
            Err(PostProcessTargetError::NoModeWithShortcut)
        );
        assert_eq!(
            resolve_post_process_target(&[], ""),
            Err(PostProcessTargetError::NoModeWithShortcut)
        );
    }

    #[test]
    fn un_modo_pedido_por_id_no_necesita_tecla() {
        assert_eq!(
            resolve_post_process_target(&prompts(), "dilo-clean"),
            Ok("dilo-clean".to_string())
        );
    }

    #[test]
    fn un_modo_se_puede_pedir_por_su_nombre() {
        // El id de un modo propio es un uuid; el nombre es lo único que la
        // persona ve.
        assert_eq!(
            resolve_post_process_target(&prompts(), " correo "),
            Ok("dilo-email".to_string())
        );
        assert_eq!(
            resolve_post_process_target(&prompts(), "CÓDIGO"),
            Ok("dilo-code".to_string())
        );
    }

    #[test]
    fn el_id_gana_sobre_un_nombre_que_coincide() {
        let ambiguo = vec![
            prompt("mi-modo", "dilo-clean", None),
            prompt("dilo-clean", "Limpio", None),
        ];
        assert_eq!(
            resolve_post_process_target(&ambiguo, "dilo-clean"),
            Ok("dilo-clean".to_string())
        );
    }

    #[test]
    fn un_modo_que_no_existe_no_cae_al_dictado_crudo() {
        assert_eq!(
            resolve_post_process_target(&prompts(), "fantasma"),
            Err(PostProcessTargetError::ModeNotFound("fantasma".to_string()))
        );
    }
}
