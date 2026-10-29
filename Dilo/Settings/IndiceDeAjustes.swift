import DiloConsumo
import DiloText
import Foundation

/// Cada ajuste que la ventana ofrece, con la sección donde vive: lo que la
/// búsqueda (⌘F) recorre y el ancla a la que salta.
///
/// Nace con el rediseño de Ajustes (Alfonso, 2026-10-19: «creo que está muy
/// simple y básica y no se condice con todas las funciones»). La promesa del
/// cambio es la del panel de la barra: **nada de lo que había se pierde**, y
/// lo que se movió se encuentra buscándolo. Un ajuste nuevo entra a este enum
/// con su sección, y su fila lleva `.anclaDeAjuste(…)` para que la búsqueda
/// la muestre; `IndiceDeAjustesTests.nadaDeLaVentanaViejaSePierde` vigila
/// que los de la 0.9.1 sigan todos.
///
/// Los títulos son las mismas claves del catálogo que las filas: si una fila
/// cambia de nombre, se cambia acá también.
enum AjusteID: String, CaseIterable, Identifiable, Hashable {
  // Dictado
  case atajoDeDictar
  case microfono
  case microfonoListo
  case entregarElTexto
  case guardarElHistorial
  case carpetaDelHistorial
  case borrarElHistorial
  case idiomaDeDictado
  case segundoIdioma
  case teclaDelSegundoIdioma
  case traducirCon
  case traducirA
  // Modos
  case tusModos
  case agregarModo
  case restaurarModos
  case queDiloElija
  case contextoApp
  case contextoTexto
  case contextoSeleccion
  case contextoSitio
  case contextoEnLinea
  case proveedorGeneral
  case modeloDelProveedor
  case urlBaseDelProveedor
  case claveDelProveedor
  // Claude
  case claveDeAnthropic
  case probarConexion
  case modeloDeLosModos
  case aprenderConClaude
  case modeloParaRevisar
  case modeloParaOrdenar
  // Tus palabras
  case tusPalabras
  case ofrecerCorrecciones
  case ordenarAhora
  case loQueOrdenoClaude
  case cuandoDigo
  case comandosAlDictar
  case sacarMuletillas
  case listaDeMuletillas
  // Historial
  case buscarEnElHistorial
  case actividad
  case latencias
  // Transcripciones
  case guardarTranscripcionEn
  case carpetaDeTranscripciones
  // Motor de voz
  case motorDeVoz
  case modeloDeParakeet
  case tusPalabrasEnParakeet
  case soltarElModelo
  // Atajos
  case teclas
  case cuantoEsUnToque
  case deshacerUnEsc
  // Apariencia
  case color
  case queSeVe
  case estiloDeLaOnda
  case paletaDelHalo
  case centroDelHalo
  case tamanoDelNotch
  case pantallasSinNotch
  case enQuePantalla
  case esperaDelHover
  case modoEnReposo
  case panelConVidrio
  case esconderAlCompartir
  case comoAparece
  case textoLargo
  case sonarAlDictar
  case juegoDeSonidos
  case volumen
  // Datos en la muesca
  case datoClaudeCode
  case datoCodex
  case datoCPU
  case datoMemoria
  case datoGPU
  case datoRed
  case datoDisco
  case porcentajeDelPlan
  case avisosDeLimite
  case agentesEnLaMuesca
  case recientesDelPortapapeles
  case proximaReunion
  case notaRapida
  case traducirEnElPanel
  case modosEnElPanel
  // General
  case abrirAlIniciarSesion
  case vozQueLee
  case traducirAntesDeLeer
  case bajarVoces
  case vozPersonal
  // Dilo
  case novedades
  case version
  case buscarActualizaciones
  case actualizacionesSolas
  case licencias

  var id: Self { self }

  var seccion: SettingsSection {
    switch self {
    case .atajoDeDictar, .microfono, .microfonoListo, .entregarElTexto, .guardarElHistorial,
      .carpetaDelHistorial, .borrarElHistorial, .idiomaDeDictado, .segundoIdioma,
      .teclaDelSegundoIdioma, .traducirA:
      .dictation
    case .claveDeAnthropic, .probarConexion, .modeloDeLosModos, .traducirCon, .aprenderConClaude,
      .modeloParaRevisar, .modeloParaOrdenar:
      .claude
    case .tusModos, .agregarModo, .restaurarModos, .queDiloElija, .contextoApp, .contextoTexto,
      .contextoSeleccion, .contextoSitio, .contextoEnLinea, .proveedorGeneral,
      .modeloDelProveedor, .urlBaseDelProveedor, .claveDelProveedor:
      .modos
    case .tusPalabras, .ofrecerCorrecciones, .ordenarAhora, .loQueOrdenoClaude, .cuandoDigo,
      .comandosAlDictar, .sacarMuletillas, .listaDeMuletillas:
      .palabras
    case .buscarEnElHistorial, .actividad, .latencias:
      .historial
    case .guardarTranscripcionEn, .carpetaDeTranscripciones:
      .dropTranscription
    case .motorDeVoz, .modeloDeParakeet, .tusPalabrasEnParakeet, .soltarElModelo:
      .motor
    case .teclas, .cuantoEsUnToque, .deshacerUnEsc:
      .shortcuts
    case .color, .queSeVe, .estiloDeLaOnda, .paletaDelHalo, .centroDelHalo, .tamanoDelNotch,
      .pantallasSinNotch, .enQuePantalla, .esperaDelHover, .modoEnReposo, .panelConVidrio,
      .esconderAlCompartir, .comoAparece, .textoLargo, .sonarAlDictar, .juegoDeSonidos, .volumen:
      .appearance
    case .datoClaudeCode, .datoCodex, .datoCPU, .datoMemoria, .datoGPU, .datoRed, .datoDisco,
      .porcentajeDelPlan, .avisosDeLimite, .agentesEnLaMuesca, .recientesDelPortapapeles,
      .proximaReunion, .notaRapida, .traducirEnElPanel, .modosEnElPanel:
      .datosDeLaMuesca
    case .abrirAlIniciarSesion, .vozQueLee, .traducirAntesDeLeer, .bajarVoces, .vozPersonal:
      .general
    case .novedades:
      .novedades
    case .version, .buscarActualizaciones, .actualizacionesSolas, .licencias:
      .about
    }
  }

  /// Si existe en este anfitrión. Lo que se esconde en Ajustes tampoco se
  /// encuentra buscando.
  var estaDisponible: Bool {
    switch self {
    case .vozQueLee, .traducirAntesDeLeer, .bajarVoces, .vozPersonal:
      SettingsSection.readAloud.isAvailable
    case .buscarActualizaciones, .actualizacionesSolas:
      SettingsSection.updates.isAvailable
    default:
      seccion.isAvailable
    }
  }

  var titulo: String {
    switch self {
    case .atajoDeDictar: String(localized: "Dictar desde cualquier app")
    case .microfono: String(localized: "Con cuál te escucho")
    case .microfonoListo: String(localized: "Dejarlo listo entre dictados")
    case .entregarElTexto: String(localized: "Entregar el texto")
    case .guardarElHistorial: String(localized: "Guardar lo que dictas")
    case .carpetaDelHistorial: String(localized: "Carpeta del historial")
    case .borrarElHistorial: String(localized: "Borrar el historial")
    case .idiomaDeDictado: String(localized: "Idioma de dictado")
    case .segundoIdioma: String(localized: "Segundo idioma")
    case .teclaDelSegundoIdioma: String(localized: "Tecla del segundo idioma")
    case .traducirCon: String(localized: "Traducir con")
    case .claveDeAnthropic: String(localized: "Clave de Anthropic")
    case .probarConexion: String(localized: "Probar conexión")
    case .modeloDeLosModos: String(localized: "Modelo de los modos")
    case .traducirA: String(localized: "Traducir a")
    case .tusModos: String(localized: "Tus modos")
    case .agregarModo: String(localized: "Agregar modo")
    case .restaurarModos: String(localized: "Restaurar los de fábrica…")
    case .queDiloElija: String(localized: "Que Dilo elija el modo")
    case .contextoApp: String(localized: "La app")
    case .contextoTexto: String(localized: "El texto alrededor del cursor")
    case .contextoSeleccion: String(localized: "Lo que tienes seleccionado")
    case .contextoSitio: String(localized: "El sitio del navegador")
    case .contextoEnLinea: String(localized: "También a proveedores en línea")
    case .proveedorGeneral: String(localized: "Quién reescribe")
    case .modeloDelProveedor: String(localized: "Modelo")
    case .urlBaseDelProveedor: String(localized: "URL base")
    case .claveDelProveedor: String(localized: "API key")
    case .tusPalabras: String(localized: "Nombres, proyectos, siglas")
    case .ofrecerCorrecciones: String(localized: "Ofrecer lo que corrijo a mano")
    case .aprenderConClaude: String(localized: "Que Claude revise y ordene")
    case .modeloParaRevisar: String(localized: "Revisar cada corrección")
    case .modeloParaOrdenar: String(localized: "Ordenar Tus palabras")
    case .ordenarAhora: String(localized: "Ordenar ahora")
    case .loQueOrdenoClaude: String(localized: "Lo que ordenó Claude")
    case .cuandoDigo: String(localized: "Cuando digo…")
    case .comandosAlDictar: String(localized: "Puntuar y editar hablando")
    case .sacarMuletillas: String(localized: "Sacar las muletillas")
    case .listaDeMuletillas: String(localized: "Tu lista de muletillas")
    case .buscarEnElHistorial: String(localized: "Buscar en el historial")
    case .actividad: String(localized: "Actividad de dictado")
    case .latencias: String(localized: "Latencia por fase")
    case .guardarTranscripcionEn: String(localized: "Guardar en")
    case .carpetaDeTranscripciones: String(localized: "Carpeta de las transcripciones")
    case .motorDeVoz: String(localized: "Motor de voz")
    case .modeloDeParakeet: String(localized: "El modelo de Parakeet")
    case .tusPalabrasEnParakeet: String(localized: "Tus palabras en Parakeet")
    case .soltarElModelo: String(localized: "Soltar el modelo de la RAM")
    case .teclas: String(localized: "Teclas")
    case .cuantoEsUnToque: String(localized: "Cuánto es un toque, en ms")
    case .deshacerUnEsc: String(localized: "Deshacer un Esc")
    case .color: String(localized: "Color")
    case .queSeVe: String(localized: "Qué se ve")
    case .estiloDeLaOnda: String(localized: "Estilo de la onda")
    case .paletaDelHalo: String(localized: "Paleta del halo")
    case .centroDelHalo: String(localized: "Centro del halo")
    case .tamanoDelNotch: String(localized: "Tamaño del notch")
    case .pantallasSinNotch: String(localized: "En pantallas sin notch")
    case .enQuePantalla: String(localized: "En qué pantalla")
    case .esperaDelHover: String(localized: "Cuánto esperar con el mouse encima")
    case .modoEnReposo: String(localized: "Decir el modo en reposo")
    case .panelConVidrio: String(localized: "Panel con vidrio")
    case .esconderAlCompartir: String(localized: "Esconderla al compartir pantalla")
    case .comoAparece: String(localized: "Cómo aparece")
    case .textoLargo: String(localized: "Si el texto se pasa de largo")
    case .sonarAlDictar: String(localized: "Sonar al dictar")
    case .juegoDeSonidos: String(localized: "Juego de sonidos")
    case .volumen: String(localized: "Volumen")
    case .datoClaudeCode: String(localized: "Claude Code")
    case .datoCodex: String(localized: "Codex")
    case .datoCPU: String(localized: "CPU")
    case .datoMemoria: String(localized: "Memoria")
    case .datoGPU: String(localized: "GPU")
    case .datoRed: String(localized: "Red")
    case .datoDisco: String(localized: "Disco")
    case .porcentajeDelPlan: String(localized: "Porcentaje de tu plan (opcional)")
    case .avisosDeLimite: String(localized: "Avisar cerca del límite")
    case .agentesEnLaMuesca: String(localized: "Mostrar agentes en la muesca")
    case .recientesDelPortapapeles: String(localized: "Lo último que copias")
    case .proximaReunion: String(localized: "Próxima reunión")
    case .notaRapida: String(localized: "Nota rápida")
    case .traducirEnElPanel: String(localized: "Traducir")
    case .modosEnElPanel: String(localized: "Cambiar de modo")
    case .abrirAlIniciarSesion: String(localized: "Abrir Dilo al iniciar sesión")
    case .vozQueLee: String(localized: "Voz que lee")
    case .traducirAntesDeLeer: String(localized: "Traducir antes de leer")
    case .bajarVoces: String(localized: "Bajar voces premium")
    case .vozPersonal: String(localized: "Voz personal")
    case .novedades: String(localized: "Novedades")
    case .version: String(localized: "Versión")
    case .buscarActualizaciones: String(localized: "Buscar actualizaciones solo")
    case .actualizacionesSolas: String(localized: "Bajarlas solo")
    case .licencias: String(localized: "Licencias de terceros")
    }
  }

  /// Lo que alguien escribiría buscándolo sin saber cómo se llama la fila:
  /// sinónimos, el nombre de una tecla, dónde estaba antes.
  var palabras: [String] {
    switch self {
    case .atajoDeDictar, .teclas: [String(localized: "atajo"), String(localized: "gatillo"), "fn", String(localized: "tecla")]
    case .microfono, .microfonoListo: [String(localized: "micrófono"), "Bluetooth", String(localized: "audífonos")]
    case .entregarElTexto: [String(localized: "pegar"), String(localized: "portapapeles"), String(localized: "copiar")]
    case .guardarElHistorial, .carpetaDelHistorial, .borrarElHistorial, .buscarEnElHistorial:
      [String(localized: "historial"), String(localized: "dictados")]
    case .idiomaDeDictado, .segundoIdioma, .teclaDelSegundoIdioma: [String(localized: "idioma"), String(localized: "español"), String(localized: "inglés")]
    case .traducirCon, .traducirA, .traducirEnElPanel, .traducirAntesDeLeer:
      [String(localized: "traducción"), String(localized: "inglés"), String(localized: "chino"), "Claude", "Haiku"]
    case .tusModos, .agregarModo, .restaurarModos, .queDiloElija, .modosEnElPanel:
      [String(localized: "modo"), String(localized: "correo"), "prompt", String(localized: "IA")]
    case .contextoApp, .contextoTexto, .contextoSeleccion, .contextoSitio, .contextoEnLinea:
      [String(localized: "contexto"), String(localized: "privacidad")]
    case .proveedorGeneral, .modeloDelProveedor, .urlBaseDelProveedor:
      [String(localized: "proveedor"), "Anthropic", "Claude", "OpenAI", "Gemini", String(localized: "modelo")]
    case .claveDelProveedor: ["API key", String(localized: "clave"), "token", String(localized: "Llavero"), "OpenAI", "Gemini"]
    case .claveDeAnthropic, .probarConexion:
      ["API key", String(localized: "clave"), "token", String(localized: "Llavero"), "Anthropic", "Claude", String(localized: "conexión")]
    case .modeloDeLosModos: ["Claude", "Haiku", "Sonnet", "Opus", String(localized: "modos"), String(localized: "costo")]
    case .tusPalabras, .cuandoDigo: [String(localized: "diccionario"), String(localized: "vocabulario"), String(localized: "reemplazo"), String(localized: "nombres")]
    case .ofrecerCorrecciones, .aprenderConClaude, .modeloParaRevisar, .modeloParaOrdenar,
      .ordenarAhora, .loQueOrdenoClaude:
      [String(localized: "aprender"), String(localized: "correcciones"), "Claude", "Haiku", "Sonnet", "Opus"]
    case .comandosAlDictar: [String(localized: "coma"), String(localized: "punto"), String(localized: "nueva línea")]
    case .sacarMuletillas, .listaDeMuletillas: [String(localized: "muletillas"), "eh", String(localized: "o sea")]
    case .actividad, .latencias: [String(localized: "estadísticas"), String(localized: "palabras"), "CSV", String(localized: "latencia")]
    case .guardarTranscripcionEn, .carpetaDeTranscripciones: [String(localized: "transcribir"), String(localized: "archivo"), "audio", "video"]
    case .motorDeVoz, .modeloDeParakeet, .soltarElModelo: ["Apple", "Parakeet", "Ultra", String(localized: "motor"), "RAM", String(localized: "memoria")]
    case .tusPalabrasEnParakeet: ["Parakeet", "CTC", String(localized: "vocabulario"), String(localized: "nombres"), String(localized: "diccionario")]
    case .cuantoEsUnToque, .deshacerUnEsc: [String(localized: "toque"), String(localized: "mantener"), "Esc", String(localized: "cancelar")]
    case .color: ["Glaciar", "Grafito", String(localized: "paleta"), String(localized: "acento")]
    case .queSeVe, .estiloDeLaOnda, .paletaDelHalo, .centroDelHalo, .comoAparece, .textoLargo:
      [String(localized: "onda"), String(localized: "halo"), String(localized: "muesca"), String(localized: "animación")]
    case .tamanoDelNotch, .pantallasSinNotch, .enQuePantalla, .esperaDelHover, .modoEnReposo,
      .panelConVidrio, .esconderAlCompartir:
      [String(localized: "muesca"), "notch", String(localized: "píldora"), String(localized: "pantalla"), "hover"]
    case .sonarAlDictar, .juegoDeSonidos, .volumen: [String(localized: "sonidos"), String(localized: "audio")]
    case .datoClaudeCode, .datoCodex, .porcentajeDelPlan, .avisosDeLimite:
      [String(localized: "consumo"), String(localized: "límite"), String(localized: "tokens"), String(localized: "muesca")]
    case .datoCPU, .datoMemoria, .datoGPU, .datoRed, .datoDisco: [String(localized: "muesca"), String(localized: "sistema"), "RAM"]
    case .agentesEnLaMuesca: ["hooks", "Claude Code", "Codex", "dilo://"]
    case .recientesDelPortapapeles, .proximaReunion, .notaRapida: [String(localized: "panel"), "hover", String(localized: "calendario"), String(localized: "Notas")]
    case .abrirAlIniciarSesion: [String(localized: "arranque"), "login"]
    case .vozQueLee, .bajarVoces, .vozPersonal: [String(localized: "leer en voz alta"), String(localized: "voz"), String(localized: "síntesis")]
    case .novedades: [String(localized: "versión"), String(localized: "cambios")]
    case .version, .buscarActualizaciones, .actualizacionesSolas: [String(localized: "actualizaciones"), "Sparkle", String(localized: "versión")]
    case .licencias: [String(localized: "licencia"), String(localized: "créditos"), String(localized: "acerca de")]
    }
  }

  /// A qué fila salta la búsqueda. Casi siempre la suya; las que comparten
  /// fila con otra —«Restaurar» vive al lado de «Agregar modo»— o que
  /// aparecen sólo a veces saltan a la vecina que siempre está.
  var ancla: AjusteID {
    switch self {
    case .restaurarModos: .agregarModo
    case .modeloDelProveedor: .proveedorGeneral
    case .vozPersonal: .bajarVoces
    case .loQueOrdenoClaude: .ordenarAhora
    default: self
    }
  }

  /// La tarjeta de una fuente de Datos en la muesca.
  static func delDato(_ dato: DatoDeLaMuesca) -> AjusteID? {
    switch dato {
    case .claude: .datoClaudeCode
    case .codex: .datoCodex
    case .cpu: .datoCPU
    case .ram: .datoMemoria
    case .gpu: .datoGPU
    case .red: .datoRed
    case .disco: .datoDisco
    case .ninguno: nil
    }
  }

  var buscable: BusquedaDeAjustes.Buscable {
    BusquedaDeAjustes.Buscable(
      id: rawValue,
      titulo: titulo,
      detalle: seccion.title + " " + seccion.subtitle,
      palabras: palabras
    )
  }
}

/// El índice entero y la búsqueda sobre él.
enum IndiceDeAjustes {
  static var disponibles: [AjusteID] {
    AjusteID.allCases.filter(\.estaDisponible)
  }

  /// Lo que calza con la consulta, del más pertinente al menos.
  static func buscar(_ consulta: String) -> [AjusteID] {
    BusquedaDeAjustes.buscar(consulta, en: disponibles.map(\.buscable))
      .compactMap(AjusteID.init(rawValue:))
  }
}
