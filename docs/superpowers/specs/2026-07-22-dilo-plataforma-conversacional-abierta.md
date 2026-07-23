# Dilo como plataforma conversacional abierta

- **Estado:** dirección de producto aprobada por el dueño (2026-07-22).
- **Alcance:** definición de producto y límites arquitectónicos.
- **No autoriza implementación:** cada superficie de extensión requiere su
  diseño técnico, revisión y plan.

## Idea central

Dilo es la pieza open source que cualquier persona puede usar para hablar o
escribir y conectarse con el sistema que prefiera. No es la interfaz exclusiva
de un producto privado ni de un proveedor de IA.

> **Dilo posee la experiencia conversacional; las capacidades pertenecen a
> conexiones reemplazables elegidas por el usuario.**

Dilo recibe voz o texto, transcribe, mantiene la interacción y presenta la
respuesta por voz, texto o ambos. El destino conectado puede ser un modelo, un
asistente, una automatización, un agente, un sistema empresarial o un backend
privado.

## Responsabilidades de Dilo

- Captura por atajo y, posteriormente, wake word opcional.
- Entrada tradicional de texto.
- STT local y selección explícita de alternativas.
- TTS local por defecto y proveedores opt-in.
- Presentación de respuestas, progreso, errores y solicitudes de aprobación.
- Configuración de conexiones y permisos visibles para el usuario.
- Experiencia útil sin conexiones externas: dictado y procesamiento local.

## Lo que vive fuera del núcleo

- Interpretación y planificación especializada.
- Orquestación de agentes.
- Reglas empresariales y políticas de negocio.
- Automatización de sistemas externos o del computador.
- CRM, ERP, proyectos, finanzas y otras aplicaciones verticales.

Estas capacidades se conectan a Dilo; no se incorporan como dependencias o
conocimiento particular del núcleo.

## Superficies de extensión

El orden propuesto, sujeto a diseño técnico posterior, es:

1. **Destino asistente genérico.** Dilo entrega una entrada textual y recibe
   progreso y respuestas por streaming. Puede ser local o remoto.
2. **Conectores instalables.** Declaran identidad, configuración, capacidades,
   permisos y uso de red o archivos mediante un manifiesto revisable.
3. **Adaptadores de protocolos.** Permiten integrarse con APIs, webhooks,
   scripts locales o protocolos abiertos como MCP sin convertirlos en
   dependencias obligatorias del núcleo.

Una implementación privada compleja debe poder usar estas mismas superficies,
actuando como integración de referencia y no como arquitectura impuesta a
todos.

## Seguridad y privacidad

- Local-first; cualquier envío a la nube es opt-in y visible.
- Credenciales en el almacén seguro del sistema operativo, no serializadas como
  texto plano en el store de configuración.
- Permisos mínimos y explícitos por conexión.
- La voz no autentica ni autoriza operaciones sensibles.
- Dilo puede mostrar o anunciar que existe una aprobación pendiente, pero la
  confirmación ocurre en una superficie visual segura.
- La respuesta hablada puede ser más breve que el resultado escrito para no
  leer datos sensibles o extensos en voz alta.

## Identidad

Dilo es el nombre del producto. La personalidad, voz, nombre del asistente y
wake word pertenecen a la configuración de cada usuario. Una personalidad
particular puede existir en una instalación sin definir la identidad pública de
Dilo.

## Criterio para futuras decisiones

Una función pertenece al núcleo sólo si mejora la experiencia conversacional
para cualquier usuario. Si conoce un negocio, agente o backend específico,
debe vivir detrás de una conexión reemplazable.
