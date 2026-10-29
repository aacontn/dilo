import DiloCapabilities
import DiloEngines
import DiloModes
import Foundation

/// Lo que dice Inicio, en palabras: si Dilo está listo para dictar, qué le
/// falta y cómo se arregla, y qué hace Claude. Puro: la vista lo dibuja y
/// los tests lo afirman sin abrir una ventana.
///
/// Alfonso, 2026-10-19: una portada que sea «el estado de un vistazo y
/// accionable». Cada aviso lleva a su arreglo —el panel exacto de Ajustes
/// del Sistema o la fila de Ajustes donde se cambia—: un aviso sin acción
/// es relleno.
struct PortadaDeAjustes: Equatable {
  struct Entrada: Equatable {
    /// Los permisos que esta copia pide (`Permiso.pasos`), y cuáles faltan.
    var permisosPedidos: [Permiso] = []
    var permisosQueFaltan: Set<Permiso> = []
    var motorElegido: SpeechEngineKind = .porDefecto
    /// Qué modelos de Parakeet hay en disco, y cuál se fijó a mano.
    var parakeetEnDisco: Set<VarianteDeParakeet> = []
    var varianteElegida: VarianteDeParakeet?
    var parakeetBajando = false
    /// Nil mientras el Llavero no contesta.
    var hayClave: Bool?
    /// Si el proveedor general de los modos es Anthropic, y con qué modelo.
    var modosConClaude = false
    var modeloDeLosModos = ModelosDeAnthropic.deFabrica.id
    var nombreDelGeneral = ""
    /// «Traducir con» elegido, o nil si decide la clave.
    var motorDeTraduccion: MotorDeTraduccion?
    var aprenderConClaude = true
    var modeloParaRevisar = ModelosDeAnthropic.deFabricaParaRevisar.id
    var modeloParaOrdenar = ModelosDeAnthropic.deFabricaParaOrdenar.id
  }

  enum Accion: Equatable {
    /// Pedir el permiso: el diálogo si todavía se puede, su panel si no.
    case pedirPermiso(Permiso)
    /// Ir a la fila de Ajustes donde se arregla.
    case ir(AjusteID)
    /// Bajar un modelo de Parakeet ahí mismo, con la barra en Motor de voz.
    case bajar(VarianteDeParakeet)
  }

  struct Aviso: Equatable, Identifiable {
    let id: String
    let icono: String
    let titulo: String
    let detalle: String
    let boton: String
    let accion: Accion
    /// Si impide dictar. Un dictado que sale pero sin Claude no bloquea.
    let bloquea: Bool
  }

  /// Una tarea que Claude puede hacer, y quién la hace hoy.
  struct Tarea: Equatable, Identifiable {
    let id: String
    let nombre: String
    let quien: String
    let conClaude: Bool
    let ajuste: AjusteID
    /// Pide Claude y no hay clave: la fila lo dice en gris, no en el color
    /// de Claude, porque hoy no corre.
    var sinClave = false
  }

  let avisos: [Aviso]
  let motorEnUso: SpeechEngineKind
  /// Cuál Parakeet dicta, si dicta Parakeet.
  let varianteEnUso: VarianteDeParakeet?
  let tareas: [Tarea]

  /// Listo para dictar: ningún aviso bloquea.
  var listo: Bool { !avisos.contains(where: \.bloquea) }

  /// Si algo está configurado para usar Claude.
  var usaClaude: Bool { tareas.contains(where: \.conClaude) }

  init(_ entrada: Entrada) {
    var avisos: [Aviso] = []

    for permiso in entrada.permisosPedidos where entrada.permisosQueFaltan.contains(permiso) {
      avisos.append(
        Aviso(
          id: "permiso.\(permiso.rawValue)",
          icono: Self.icono(de: permiso),
          // El nombre y el porqué son contenido de `Permiso` y salen tal
          // cual, como en los Primeros pasos.
          titulo: String(localized: "Falta el permiso de \(permiso.titulo)"),
          detalle: permiso.porque,
          boton: String(localized: "Dar permiso"),
          accion: .pedirPermiso(permiso),
          bloquea: true
        )
      )
    }

    let seleccion = EngineResolver.resolver(
      elegido: entrada.motorElegido,
      parakeetEnDisco: entrada.parakeetEnDisco,
      varianteElegida: entrada.varianteElegida
    )
    motorEnUso = seleccion.efectivo
    varianteEnUso = seleccion.varianteDeParakeet
    let recomendada = VarianteDeParakeet.recomendada
    if entrada.motorElegido == .parakeet, entrada.parakeetEnDisco.isEmpty {
      avisos.append(
        Aviso(
          id: "parakeet",
          icono: "arrow.down.circle",
          titulo: entrada.parakeetBajando
            ? String(localized: "Parakeet se está bajando")
            : String(localized: "Parakeet todavía no está en este Mac"),
          detalle: entrada.parakeetBajando
            ? String(localized: "Mientras tanto dicta Apple. No te vas a quedar sin dictar.")
            : String(localized: "Son \(recomendada.megasDeDescarga) MB. Mientras tanto dicta Apple: no te vas a quedar sin dictar."),
          boton: entrada.parakeetBajando
            ? String(localized: "Ver")
            : String(localized: "Bajar \(recomendada.nombre)"),
          accion: entrada.parakeetBajando ? .ir(.modeloDeParakeet) : .bajar(recomendada),
          bloquea: false
        )
      )
    } else if entrada.motorElegido == .parakeet,
      let ofrecida = ResolucionDeParakeet.paraBajar(enDisco: entrada.parakeetEnDisco)
    {
      // Quien ya tiene v3 sigue dictando con v3: nada se baja solo. Se le
      // ofrece Ultra con su tamaño, y no bloquea nada.
      avisos.append(
        Aviso(
          id: "parakeet.\(ofrecida.rawValue)",
          icono: "sparkles",
          titulo: entrada.parakeetBajando
            ? String(localized: "\(ofrecida.nombre) se está bajando")
            : String(localized: "Hay un Parakeet más preciso"),
          detalle: String(localized: "\(ofrecida.nombre) se equivoca menos y es igual de rápido. Son \(ofrecida.megasDeDescarga) MB; mientras bajan, sigues dictando como hoy."),
          boton: entrada.parakeetBajando
            ? String(localized: "Ver")
            : String(localized: "Bajar \(ofrecida.nombre)"),
          accion: entrada.parakeetBajando ? .ir(.modeloDeParakeet) : .bajar(ofrecida),
          bloquea: false
        )
      )
    }

    let traduceClaude = entrada.motorDeTraduccion == .claude
      || (entrada.motorDeTraduccion == nil && entrada.hayClave == true)
    let tareas = [
      Tarea(
        id: "modos",
        nombre: String(localized: "Modos"),
        quien: entrada.modosConClaude
          ? Self.nombre(entrada.modeloDeLosModos)
          : entrada.nombreDelGeneral,
        conClaude: entrada.modosConClaude,
        ajuste: .modeloDeLosModos
      ),
      Tarea(
        id: "traducir",
        nombre: String(localized: "Traducir"),
        quien: traduceClaude
          ? ModelosDeAnthropic.haiku.nombre
          : String(localized: "Apple, en el Mac"),
        conClaude: traduceClaude,
        ajuste: .traducirCon
      ),
      Tarea(
        id: "revisar",
        nombre: String(localized: "Revisar correcciones"),
        quien: entrada.aprenderConClaude ? Self.nombre(entrada.modeloParaRevisar) : String(localized: "Apagado"),
        conClaude: entrada.aprenderConClaude,
        ajuste: .modeloParaRevisar
      ),
      Tarea(
        id: "ordenar",
        nombre: String(localized: "Ordenar Tus palabras"),
        quien: entrada.aprenderConClaude ? Self.nombre(entrada.modeloParaOrdenar) : String(localized: "Apagado"),
        conClaude: entrada.aprenderConClaude,
        ajuste: .modeloParaOrdenar
      ),
    ]
    let sinClave = entrada.hayClave == false
    self.tareas = tareas.map { tarea in
      var tarea = tarea
      tarea.sinClave = sinClave && tarea.conClaude
      return tarea
    }

    // Sin clave, lo que pide Claude cae a lo de antes o no corre: no impide
    // dictar, pero hay que decirlo, y una sola vez.
    if sinClave, tareas.contains(where: \.conClaude) {
      avisos.append(
        Aviso(
          id: "clave",
          icono: "key.fill",
          titulo: String(localized: "Falta la clave de Anthropic"),
          detalle: String(localized: "Sin ella, los modos con Claude no corren y aprender y traducir vuelven a lo de antes."),
          boton: String(localized: "Pegar la clave"),
          accion: .ir(.claveDeAnthropic),
          bloquea: false
        )
      )
    }
    self.avisos = avisos
  }

  static func nombre(_ modelo: String) -> String {
    ModelosDeAnthropic.conocido(modelo)?.nombre ?? modelo
  }

  static func icono(de permiso: Permiso) -> String {
    switch permiso {
    case .microfono: "mic.slash.fill"
    case .reconocimientoDeVoz: "waveform.badge.exclamationmark"
    case .accesibilidad: "hand.raised.fill"
    case .monitoreoDeEntrada: "keyboard.badge.ellipsis"
    }
  }
}
