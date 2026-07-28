<!--
Sync Impact Report
- Version change: (none) → 1.0.0
- Modified principles: n/a (initial ratification)
- Added sections:
  - Core Principles: I. Núcleo Abierto y Agnóstico, II. Dilo Propone, Nunca
    Ejecuta, III. Español Primero Sin Traducción Automática, IV. Cerca del
    Upstream (Handy), V. Calidad No Negociable, VI. Sin Atajos de Alcance
  - Restricciones Técnicas y Arquitectura
  - Flujo de Desarrollo
  - Governance
- Removed sections: none (first ratification from template placeholders)
- Templates requiring updates:
  - ✅ .specify/templates/plan-template.md (Constitution Check gate already
    generic — references "Constitution" directly, no changes needed)
  - ✅ .specify/templates/spec-template.md (no principle-specific mandatory
    sections needed beyond existing structure)
  - ✅ .specify/templates/tasks-template.md (generic task categorization
    already compatible; no principle-driven task types to add beyond what
    existing categories cover)
  - ✅ .claude/skills/speckit-*/SKILL.md (generic, agent-agnostic — no
    hardcoded references to other agents found)
  - ⚠ CLAUDE.md / AGENTS.md — already contain the source material this
    constitution codifies; no contradictions found, no edits required, but
    not yet cross-referenced to point at .specify/memory/constitution.md.
    Left as a follow-up, not done here (out of scope for constitution-only
    changes; suggested as a Next Action below).
- Follow-up TODOs: none blocking.
-->

# Dilo Constitution

## Core Principles

### I. Núcleo Abierto y Agnóstico (NON-NEGOTIABLE)

Dilo es una interfaz conversacional universal, no el cliente cautivo de un
backend, agente o negocio particular. El núcleo NUNCA codifica el nombre,
reglas de negocio ni dependencias de un backend específico. Las capacidades
externas entran exclusivamente por contratos genéricos y reemplazables: un
destino asistente configurable, conectores con manifiesto de permisos
explícito y, cuando corresponda, protocolos como MCP. Una instalación
privada puede ser muy potente sin que esa implementación se convierta en la
arquitectura pública del producto.

**Rationale**: es lo que mantiene a Dilo open source y evita que las
decisiones de un cliente o backend particular capturen el roadmap del
núcleo.

### II. Dilo Propone, Nunca Ejecuta

La voz puede proponer o preparar una acción, pero nunca autentica ni
autoriza una operación sensible (enviar, borrar, comprar, modificar
sistemas) sin confirmación visual segura del usuario. Dilo posee la
experiencia conversacional — captura, STT, TTS, sesión, progreso y
presentación —; el backend conectado interpreta, planifica y ejecuta. Dilo
NUNCA se convierte en ERP, orquestador de agentes ni autoridad de negocio.
Las credenciales de conectores no se guardan en texto plano.

**Rationale**: separar "quién habla" de "quién decide" es lo que hace
seguro exponer Dilo a agentes con permisos reales.

### III. Español Primero, Sin Traducción Automática

El copy en español (`es`) es la voz de marca del producto, escrito a mano —
NUNCA generado ni regenerado por máquina. El resto de los idiomas siguen
las guías de `CONTRIBUTING_TRANSLATIONS.md`. Todo string visible al usuario
pasa por i18next; ESLint rechaza strings hardcodeados en JSX.

**Rationale**: Dilo es un producto es-first para vibe coders de LATAM, no
una traducción de un producto pensado en inglés — perder esa voz es perder
el producto.

### IV. Cerca del Upstream (Handy)

El backend Rust se mantiene lo más cerca posible de `upstream/main` (Handy,
cjpais) para que `git fetch upstream && git merge upstream/main` siga
siendo barato. Cambios de marca, UI y defaults van en commits enfocados,
separados de la lógica core. Bugfixes que también apliquen a upstream se
contribuyen a Handy primero cuando sea razonable, y se mergean de vuelta acá.

**Rationale**: divergir demasiado del upstream cambia el costo de mantener
el fork de "mergear" a "reescribir", y ese costo compone en cada release.

### V. Calidad No Negociable

`cargo fmt` + `cargo clippy` en Rust, ESLint + Prettier en frontend,
TypeScript estricto sin `any`, corren antes de cada commit. Los mensajes de
commit usan prefijo convencional (`feat:`, `fix:`, `docs:`, `refactor:`,
`chore:`) enfocado en el *por qué*, no el *qué*.

**Rationale**: en un fork abierto sin feature freeze, la disciplina de
código es lo único que evita que la velocidad de shippear se convierta en
deuda técnica silenciosa.

### VI. Sin Atajos de Alcance (NON-NEGOTIABLE)

Ninguna feature se declara "lista" con una versión recortada que no despeje
la barra de diferenciación real, solo porque es más rápida de shippear. Si
el equipo decide construir algo, se construye la versión que resuelve el
problema difícil — no la versión de post-proceso liviano que cualquiera
puede clonar en un día — o se pausa y documenta explícitamente por qué se
difiere el alcance completo, en vez de shippear un downgrade silencioso
presentado como el producto final.

**Rationale**: nacida de la decisión del 2026-07-27 de no shippear un
notetaker de reuniones "solo post-proceso, sin diarización" — la ventaja
competitiva de Dilo está en resolver lo difícil (ej. diarización presencial
local/offline), no en llegar primero con lo fácil.

## Restricciones Técnicas y Arquitectura

- Stack: Tauri 2.x (backend Rust + frontend React/TypeScript). Patrón de
  managers (Audio, Model, Transcription, History, ...) inicializados al
  arrancar y expuestos vía estado de Tauri. Comunicación
  comando-evento: frontend → backend por comandos Tauri, backend → frontend
  por eventos.
- Licencia: MIT. Copyright compartido — CJ Pais (Handy, proyecto original)
  y Alfonso Contreras (Dilo). Cualquier derivado (fork, rebrand, build
  redistribuido) debe conservar el aviso de copyright y el texto de la
  licencia; esto no es negociable ni siquiera cuando el derivado agrega
  features propias.
- Plataformas: macOS (Metal, permisos de accesibilidad), Windows (Vulkan,
  firma de código), Linux (OpenBLAS + Vulkan, soporte Wayland limitado,
  overlay vía GTK layer shell).
- CLI: los flags de línea de comandos son overrides de runtime — NUNCA
  modifican settings persistidos.

## Flujo de Desarrollo

- Sin feature freeze: la dirección de producto la marca el maintainer, vive
  en `docs/superpowers/specs/`. Una dirección de producto documentada ahí
  no es autorización automática para implementar — cuando el spec lo dice
  explícitamente, hace falta diseño técnico y plan antes de tocar código.
- Bugfixes que también aplican a upstream se contribuyen a Handy primero
  siguiendo sus reglas de contribución, después se mergean de vuelta acá.
- Traducciones siguen `CONTRIBUTING_TRANSLATIONS.md`; el locale `es` nunca
  se regenera por máquina (ver Principio III).
- `CLAUDE.md` es la fuente de verdad para guía de agentes de IA; `AGENTS.md`
  es una copia byte-idéntica (un test guardián falla si divergen). Editar
  siempre `CLAUDE.md` primero.

## Governance

Esta constitución tiene precedencia sobre cualquier práctica ad-hoc,
incluida la guía de `CLAUDE.md` cuando haya conflicto directo — en ese caso,
se corrige `CLAUDE.md`, no se ignora la constitución.

**Enmiendas**: cualquier cambio a esta constitución sigue versionado
semántico — MAJOR para remociones o redefiniciones incompatibles de
principios, MINOR para principios o secciones nuevas, PATCH para
clarificaciones sin cambio semántico. Cada enmienda actualiza `Last
Amended` y agrega su propio Sync Impact Report al tope del archivo.

**Cumplimiento**: cada spec generada con `/speckit-specify` y cada plan
generado con `/speckit-plan` se valida contra esta constitución (Constitution
Check). `/speckit-analyze` es la herramienta de verificación de consistencia
entre spec, plan y tasks antes de `/speckit-implement`.

**Guía de runtime**: para desarrollo día a día (comandos, estructura de
código, i18n, debug), usar `CLAUDE.md` — esta constitución gobierna
principios, `CLAUDE.md` gobierna el cómo.

**Version**: 1.0.0 | **Ratified**: 2026-07-22 | **Last Amended**: 2026-07-27
