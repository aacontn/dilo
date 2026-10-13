import AppKit
import DiloCapabilities
import os

/// La entrega de un dictado terminado: el portapapeles prometido, el ⌘V, la
/// espera de una señal y la devolución de lo que la persona tenía copiado.
///
/// La regla de todo esto: **un dictado no se pierde en silencio**. Lo que no
/// se pega vuelve como `.retenido` para la tarjeta del notch, y mientras ella
/// dure se queda en el portapapeles para pegarlo a mano.
extension TextInsertionService {
  /// Entrega `texto` según el destino de Ajustes.
  ///
  /// Contesta en cuanto sabe cómo le fue —casi siempre en lo que tarda la
  /// app en leer, menos de 200 ms—; devolver el portapapeles sigue después,
  /// en `tareaDeDevolucion`, para que la muesca no espere a nadie.
  func entregar(
    _ texto: String,
    a destino: Target?,
    segun ajuste: InsertionDestination = .insert
  ) async -> ResultadoDeEntrega {
    guard !texto.isEmpty else { return .nadaQueEntregar }
    guard ajuste != .clipboardOnly else {
      return copiar(texto) ? .copiado : .retenido(.sinRespaldo)
    }
    guard let destino, dependencies.isProcessRunning(destino.processIdentifier) else {
      return await dejarParaPegarAMano(texto, porque: .focoCambio, quedarse: ajuste == .both)
    }

    let resultado = await entregarConPromesa(texto, en: destino, devolver: ajuste == .insert)
    if ajuste == .both {
      // «Pegar y copiar» es el mismo camino sin devolver: el dictado queda
      // como una copia cualquiera, también si no se pegó.
      if let pendiente = pegadoPendiente {
        tareaDeDevolucion?.cancel()
        Self.materializar(pendiente, en: dependencies.pasteboard)
        pegadoPendiente = nil
      } else if case .retenido = resultado {
        _ = copiar(texto)
      }
    }
    return resultado
  }

  /// Pega `texto` en el destino con promesa, verificación y respaldo.
  ///
  /// - Parameter devolver: false en «Pegar y copiar»: no hay nada que
  ///   devolver, así que tampoco hay foto que tomar ni presupuesto que gastar
  ///   en ella.
  func entregarConPromesa(
    _ texto: String,
    en destino: Target,
    devolver: Bool
  ) async -> ResultadoDeEntrega {
    let pasteboard = dependencies.pasteboard
    let reloj = dependencies.clock
    let politica = dependencies.politica(destino)
    let tiempos = politica.tiempos
    // El cursor y el campo sólo se miran donde sirven: en una terminal el
    // cursor se mueve con cada línea que imprime y el valor es el historial.
    let ancla = politica.verificarElCampo ? destino.ancla : nil
    // Cómo estaba el campo, leído fuera del actor principal mientras se
    // fotografía el portapapeles: así no suma a lo que tarda el pegado.
    let fotoDeAntes = ancla.map { ancla in
      Task { [fotoDelCampo = dependencies.fotoDelCampo] in await fotoDelCampo(ancla) }
    }

    // 1. La foto: heredada si el dictado anterior sigue esperando volver.
    //    En «Pegar y copiar» lo heredado se suelta igual: lo que la persona
    //    pidió es quedarse con el dictado nuevo.
    let heredada = heredarPendiente()
    let foto: [ClipboardItemSnapshot]
    let conteoAceptado: Int
    if let heredada, devolver {
      foto = heredada.foto
      conteoAceptado = heredada.changeCount
    } else if devolver {
      switch await snapshotClipboardItems() {
      case let .accepted(items, changeCount):
        foto = items
        conteoAceptado = changeCount
      case .failed, .timedOut, .unstable, .busy:
        // Lo de la persona no se puede guardar, así que no se toca: el
        // dictado se ofrece en la tarjeta.
        return .retenido(.sinRespaldo)
      }
    } else {
      foto = []
      conteoAceptado = pasteboard.changeCount
    }

    // 2. El teclado libre, y el foco y el cursor donde estaban.
    if let motivo = await dependencies.teclado.esperarTecladoLibre(
      ahora: reloj.now,
      dormir: reloj.sleep
    ) {
      return dejar(texto, foto: foto, conteo: conteoAceptado, porque: motivo, tiempos: tiempos)
    }
    guard sigueAhi(destino, ancla: ancla) else {
      return dejar(texto, foto: foto, conteo: conteoAceptado, porque: .focoCambio, tiempos: tiempos)
    }
    let antes = await fotoDeAntes?.value
    let campo = ancla.flatMap { ancla in antes.map { (ancla: ancla, antes: $0) } }
      .flatMap { $0.antes.esLegible ? $0 : nil }

    // 3. La promesa, sólo si nadie tocó el portapapeles desde la foto.
    guard !isClipboardReadActive(), pasteboard.changeCount == conteoAceptado,
      let pendiente = Self.escribirPromesa(texto, foto: foto, en: pasteboard, ahora: reloj.now)
    else { return .retenido(.portapapelesAjeno) }
    pegadoPendiente = pendiente

    // 4. Última verificación y ⌘V, sin ningún `await` entre medio: lo que
    //    cambie después de mirar tiene que ser lo que se pegue.
    guard sigueAhi(destino, ancla: ancla) else {
      return quedarseParaPegarAMano(pendiente, porque: .focoCambio, tiempos: tiempos)
    }
    let canal = canal(para: destino)
    pendiente.promesa.marcarDespachado()
    guard dependencies.postPasteShortcut(canal) else {
      return quedarseParaPegarAMano(pendiente, porque: .sinAtajo, tiempos: tiempos)
    }
    let inicio = reloj.now()

    // 5. Esperar la señal y decidir.
    let senal = await vigilar(pendiente, campo: campo, texto: texto, tiempos: tiempos, desde: inicio)
    let decision = DecisionTrasLaSenal.para(
      senal,
      ahora: reloj.now(),
      tiempos: tiempos,
      puedeTeclear: politica.reintentarTecleando && campo != nil
    )
    if case .reintentarTecleando = decision, let campo {
      return await reintentarTecleando(
        texto, pendiente: pendiente, en: destino, campo: campo, canal: canal, tiempos: tiempos)
    }
    return terminar(pendiente, con: decision, tiempos: tiempos)
  }

  /// Si el foco sigue en el destino y, con ancla, el cursor donde estaba. Un
  /// cursor que se movió no es un pegado en otro lado: es la tarjeta.
  private func sigueAhi(_ destino: Target, ancla: AnclaDelFoco?) -> Bool {
    dependencies.isTargetFocused(destino) && (ancla.map(dependencies.anclaSigueIgual) ?? true)
  }

  /// Aplica una decisión que ya no pide teclear.
  private func terminar(
    _ pendiente: PegadoPendiente,
    con decision: DecisionTrasLaSenal,
    tiempos: TiemposDePegado
  ) -> ResultadoDeEntrega {
    guard case let .terminar(resultado, plan) = decision else {
      // Teclear se decide antes de llegar acá; si llega, se trata como «no
      // entró»: el dictado queda para pegarlo a mano.
      return quedarseParaPegarAMano(pendiente, porque: .noEntro, tiempos: tiempos)
    }
    if let plan {
      programarDevolucion(pendiente, segun: plan, tiempos: tiempos)
    } else if pegadoPendiente?.marca == pendiente.marca {
      // Ya no es de Dilo: un dictado nuevo pudo dejar el suyo.
      pegadoPendiente = nil
    }
    return resultado
  }

  /// El ⌘V no movió el campo: se teclea una vez y se vuelve a mirar. Nunca
  /// dos: si tampoco entra, el dictado queda en la tarjeta y en el
  /// portapapeles.
  private func reintentarTecleando(
    _ texto: String,
    pendiente: PegadoPendiente,
    en destino: Target,
    campo: (ancla: AnclaDelFoco, antes: FotoDelCampo),
    canal: CanalDelAtajo,
    tiempos: TiemposDePegado
  ) async -> ResultadoDeEntrega {
    let reloj = dependencies.clock
    // Sin ningún `await` entre esta mirada y el primer evento.
    guard dependencies.teclado.sePuedeTeclear, sigueAhi(destino, ancla: campo.ancla) else {
      return quedarseParaPegarAMano(pendiente, porque: .noEntro, tiempos: tiempos)
    }
    guard await dependencies.teclear(TecleoDelDictado.pedazos(de: texto), canal) else {
      return quedarseParaPegarAMano(pendiente, porque: .noEntro, tiempos: tiempos)
    }
    try? await reloj.sleep(tiempos.lecturaTrasTeclear)
    let despues = await dependencies.fotoDelCampo(campo.ancla)
    let veredicto = VeredictoDelCampo.comparar(antes: campo.antes, despues: despues, texto: texto)
    AppLog.delivery.info("tecleado: \(String(describing: veredicto), privacy: .public)")
    return terminar(
      pendiente,
      con: .trasTeclear(veredicto, ahora: reloj.now(), tiempos: tiempos),
      tiempos: tiempos
    )
  }

  /// Espera la primera señal del pegado: el acuse, el campo o nada.
  func vigilar(
    _ pendiente: PegadoPendiente,
    campo: (ancla: AnclaDelFoco, antes: FotoDelCampo)?,
    texto: String,
    tiempos: TiemposDePegado,
    desde inicio: Duration
  ) async -> SenalDeEntrega {
    let reloj = dependencies.clock
    let pasteboard = dependencies.pasteboard
    var vigia = VigiaDelPegado(inicio: inicio, tiempos: tiempos, verificaElCampo: campo != nil)
    while true {
      let paso = vigia.siguiente(
        ahora: reloj.now(),
        esDeDilo: Self.esDeDilo(pendiente, en: pasteboard),
        lectura: pendiente.promesa.lecturaValida,
        huboEntradaDeLaPersona: { dependencies.huboEntradaDeLaPersona(reloj.now() - inicio) }
      )
      switch paso {
      case let .terminar(senal):
        return senal
      case .leerElCampo:
        guard let campo else { continue }
        let despues = await dependencies.fotoDelCampo(campo.ancla)
        vigia.anotar(VeredictoDelCampo.comparar(antes: campo.antes, despues: despues, texto: texto))
      case let .esperar(duracion):
        do { try await reloj.sleep(duracion) } catch { return .cancelado }
      }
    }
  }

  /// Si el dictado anterior sigue en el portapapeles esperando volver, lo da
  /// por terminado y devuelve su foto, que es la de antes de los dos.
  private func heredarPendiente() -> PegadoPendiente? {
    guard let anterior = pegadoPendiente else { return nil }
    tareaDeDevolucion?.cancel()
    tareaDeDevolucion = nil
    pegadoPendiente = nil
    anterior.promesa.detener()
    guard Self.esDeDilo(anterior, en: dependencies.pasteboard) else { return nil }
    AppLog.delivery.info("portapapeles: \(MotivoDeDevolucion.heredado.rawValue, privacy: .public)")
    return anterior
  }

  /// Un dictado que no se va a pegar se queda en el portapapeles mientras
  /// dura la tarjeta, para pegarlo a mano con ⌘V; después vuelve lo de la
  /// persona. Sin foto no se toca nada: lo suyo no se puede devolver.
  private func dejar(
    _ texto: String,
    foto: [ClipboardItemSnapshot],
    conteo: Int,
    porque motivo: MotivoParaNoPegar,
    tiempos: TiemposDePegado
  ) -> ResultadoDeEntrega {
    let pasteboard = dependencies.pasteboard
    guard !isClipboardReadActive(), pasteboard.changeCount == conteo,
      let pendiente = Self.escribirPromesa(
        texto, foto: foto, en: pasteboard, ahora: dependencies.clock.now)
    else { return .retenido(motivo) }
    pegadoPendiente = pendiente
    return quedarseParaPegarAMano(pendiente, porque: motivo, tiempos: tiempos)
  }

  /// La promesa ya está escrita y no hubo ⌘V: desde ya cualquier lectura es
  /// la persona pegando, y lo suyo vuelve medio segundo después.
  private func quedarseParaPegarAMano(
    _ pendiente: PegadoPendiente,
    porque motivo: MotivoParaNoPegar,
    tiempos: TiemposDePegado
  ) -> ResultadoDeEntrega {
    pendiente.promesa.marcarDespachado()
    programarDevolucion(
      pendiente,
      segun: PlanDeDevolucion(
        limite: dependencies.clock.now() + tiempos.esperaSinSenal,
        motivo: .trasEsperar
      ),
      tiempos: tiempos
    )
    return .retenido(motivo)
  }

  /// Sin destino: la foto se toma acá, para lo mismo que `dejar`.
  private func dejarParaPegarAMano(
    _ texto: String,
    porque motivo: MotivoParaNoPegar,
    quedarse: Bool
  ) async -> ResultadoDeEntrega {
    guard !quedarse else {
      _ = copiar(texto)
      return .retenido(motivo)
    }
    let foto: [ClipboardItemSnapshot]
    let conteo: Int
    if let heredada = heredarPendiente() {
      foto = heredada.foto
      conteo = heredada.changeCount
    } else if case let .accepted(items, changeCount) = await snapshotClipboardItems() {
      foto = items
      conteo = changeCount
    } else {
      return .retenido(motivo)
    }
    return dejar(texto, foto: foto, conteo: conteo, porque: motivo, tiempos: .deFabrica)
  }

  /// Devuelve el portapapeles cuando diga el plan, salvo que otro dictado
  /// herede la foto antes. Si la persona pega a mano mientras se espera, el
  /// acuse llega y la devolución se adelanta.
  func programarDevolucion(
    _ pendiente: PegadoPendiente,
    segun plan: PlanDeDevolucion,
    tiempos: TiemposDePegado
  ) {
    tareaDeDevolucion?.cancel()
    pegadoPendiente = pendiente
    let reloj = dependencies.clock
    tareaDeDevolucion = Task { [weak self] in
      var plan = plan
      while true {
        if let lectura = pendiente.promesa.lecturaValida {
          plan.anotarLectura(en: lectura, gracia: tiempos.graciaTrasLectura)
        }
        let falta = plan.limite - reloj.now()
        guard falta > .zero else { break }
        do { try await reloj.sleep(min(falta, tiempos.sondeo)) } catch { return }
      }
      guard let self, !Task.isCancelled else { return }
      // Una lectura en curso todavía es dueña del portapapeles: escribir
      // encima es lo que el contrato de la foto prohíbe. Se espera a que
      // suelte, y si no suelta, el dictado se queda donde está.
      var intentos = 0
      while self.isClipboardReadActive(), intentos < 40 {
        intentos += 1
        do { try await reloj.sleep(tiempos.sondeo) } catch { return }
      }
      guard !self.isClipboardReadActive() else { return }
      let motivo = Self.devolver(pendiente, en: self.dependencies.pasteboard, motivo: plan.motivo)
      if self.pegadoPendiente?.marca == pendiente.marca { self.pegadoPendiente = nil }
      AppLog.delivery.info("portapapeles: \(motivo.rawValue, privacy: .public)")
    }
  }

  /// Lo de la persona vuelve ya, sin esperar: antes de leer o de escribir el
  /// portapapeles por otro motivo. Una foto tomada con el dictado todavía
  /// prometido leería la promesa —y la tomaría por un pegado— y guardaría el
  /// dictado como si fuera lo de la persona.
  func devolverElPendienteAhora() {
    guard let pendiente = pegadoPendiente else { return }
    tareaDeDevolucion?.cancel()
    tareaDeDevolucion = nil
    pegadoPendiente = nil
    let motivo = Self.devolver(pendiente, en: dependencies.pasteboard, motivo: .trasEsperar)
    AppLog.delivery.info("portapapeles: \(motivo.rawValue, privacy: .public)")
  }

  /// Al cerrar Dilo: una promesa cuyo dueño murió no entrega nada. Si la app
  /// ya leyó, vuelve lo de la persona; si nadie leyó, el dictado se queda
  /// como texto de verdad, porque puede ser lo único que lo tiene.
  func alCerrar() {
    guard let pendiente = pegadoPendiente else { return }
    tareaDeDevolucion?.cancel()
    pegadoPendiente = nil
    if pendiente.promesa.lecturaValida != nil {
      _ = Self.devolver(pendiente, en: dependencies.pasteboard, motivo: .alCerrar)
    } else {
      Self.materializar(pendiente, en: dependencies.pasteboard)
    }
  }
}
