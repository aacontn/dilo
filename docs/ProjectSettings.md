# Valores de proyecto

Los valores que hay que reponer a mano si alguna vez se vuelve a armar
`Talkify.xcodeproj` desde cero. Desciende del documento homónimo de Talkify
(Tornike Gomareli, MIT), actualizado a Dilo.

## Identidad — dos targets

| | `Dilo` | `Dilo-MAS` |
| --- | --- | --- |
| Bundle ID | `cl.espaciodigital.dilo` | `cl.espaciodigital.dilo.mas` |
| Producto | `Dilo.app` | `Dilo-MAS.app` (nombre visible: Dilo) |
| App Sandbox | NO | SÍ |
| Sparkle | sí | no (condición `DILO_MAS`) |
| Entitlements | `Dilo.entitlements` | `Dilo-MAS.entitlements` |
| Para qué | venta directa | App Store |

Comunes: app de macOS, deployment target 26.0, sólo `arm64`, categoría
`public.app-category.productivity`, versión de marketing `0.4.0`, build `400`.

El target de tests se llama `DiloTests` y su bundle es
`cl.espaciodigital.dilo.tests`. Las carpetas siguen llamándose `Talkify/` y
`TalkifyTests/` a propósito: renombrarlas convertiría cada
`git merge upstream/main` en un campo de conflictos de rename.

## Claves de Info.plist que importan

- `LSUIElement` = true (sólo barra de menús, sin ícono en el Dock)
- `NSMicrophoneUsageDescription` = "Dilo usa el micrófono para transcribir lo
  que dictas, en esta compu."
- `NSSpeechRecognitionUsageDescription` = "Dilo convierte tu voz en texto en
  esta compu."
- `NSPrincipalClass` = `NSApplication`
- `NSHighResolutionCapable` no se pone: viene en true para apps enlazadas
  contra SDKs modernos y el Info.plist generado de Xcode no tiene un
  `INFOPLIST_KEY_` para él.

### Claves de Sparkle (`Talkify/Info.plist`, sólo target `Dilo`)

El target mantiene `GENERATE_INFOPLIST_FILE = YES` **y** además apunta
`INFOPLIST_FILE = Talkify/Info.plist`; Xcode fusiona las claves generadas en
ese archivo. El plist existe sólo porque Sparkle lee `SUPublicEDKey` directo
del bundle y el passthrough `INFOPLIST_KEY_<nombre>` de Xcode descarta en
silencio las claves que no conoce. (Razón heredada de Talkify, sigue siendo
cierta.)

- `SUFeedURL` = el appcast de Dilo. **Todavía no existe: Tarea 8.**
- `SUPublicEDKey` = **hoy es la llave de Talkify.** Tarea 8 genera la de Dilo
  con `scripts/setup-sparkle-keys.sh`; la mitad privada vive en el Llavero y
  nunca en el repo.
- `SUEnableAutomaticChecks` = **false** hasta que existan feed y llave
  propios. Con el feed de Talkify apuntado acá, Dilo ofrecería Talkify 0.8.3
  como actualización de sí mismo y la llave la verificaría.
- `SUScheduledCheckInterval` = 86400 (una vez al día)
- `SUAllowsAutomaticUpdates` = true (bajar solo sigue apagado por defecto)

`Dilo-MAS` no tiene `INFOPLIST_FILE`: su plist se genera entero y no lleva
ninguna clave de Sparkle.

## Entitlements

`Dilo.entitlements` — App Sandbox apagado; hace falta para el tap de CGEvent
y la inserción por Accesibilidad. Hardened Runtime encendido.

```xml
<key>com.apple.security.device.audio-input</key><true/>
```

`Dilo-MAS.entitlements` — App Sandbox encendido:

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.files.user-selected.read-only</key><true/>
```

## Firma

**Hoy los dos targets firman "Sign to Run Locally"**: `CODE_SIGN_IDENTITY = "-"`,
`CODE_SIGN_STYLE = Manual`, `DEVELOPMENT_TEAM` vacío, en Debug y en Release.
La Tarea 8 pone Developer ID + notarización para `Dilo` y firma de App Store
para `Dilo-MAS`.

## Build settings

Base: `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`,
`DEAD_CODE_STRIPPING = YES`, `ONLY_ACTIVE_ARCH = NO`.

Desvíos deliberados respecto de la plantilla de Xcode:
`SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` y
`SWIFT_APPROACHABLE_CONCURRENCY = NO`. Los componentes heredados fueron
escritos para concurrencia estricta clásica con `@MainActor` explícito; el
aislamiento MainActor por defecto cambiaría el de sus clases sin anotar (por
ejemplo los callbacks del hilo de audio en `MicrophoneInput`).

`Dilo-MAS` agrega `DILO_MAS` a `SWIFT_ACTIVE_COMPILATION_CONDITIONS`. Es lo
que deja Sparkle fuera de ese binario y esconde el panel Actualizaciones.

## Paquete local

`DiloCore/` entra como `XCLocalSwiftPackageReference` y sus productos se
enlazan en **los dos** targets. Cuando nazca un módulo nuevo hay que agregarlo
al `Package.swift`, al `packageProductDependencies` de los dos targets y a la
tabla de `AGENTS.md`.

## Idiomas

`developmentRegion = es`, `knownRegions = (es, en, Base)`. El español es el
idioma en que se escribe el copy; el inglés se traduce desde ahí, nunca al
revés.
