// Técnica observada en AeriVoice 0.2.5 (marca propia con un UUID por pegado,
// devolver con rescate si la escritura falla, foto con topes de 64 MiB, 128
// ítems y 1 024 tipos), Spokenly 2.31 (`.currentHostOnly`) e
// imnotpayingforwisprflow (`changeCount` y marca juntos); implementación
// propia.
import AppKit
import DiloCapabilities

extension TextInsertionService {
  /// El tipo propio que dice «esto lo escribió Dilo, en este pegado». Lleva
  /// un UUID distinto en cada pegado.
  ///
  /// `changeCount` solo no alcanza: un gestor de portapapeles que reescribe
  /// lo mismo lo mueve y Dilo dejaría de reconocer lo suyo; y al revés, la
  /// marca sola no ve que alguien copió encima. Se miran los dos.
  static let tipoDeLaMarca = NSPasteboard.PasteboardType("cl.espaciodigital.dilo.clipboard-owner")

  /// Un dictado que está en el portapapeles esperando ser leído, y lo que
  /// había antes, esperando volver.
  struct PegadoPendiente {
    /// Lo que había antes del primer dictado de la cadena. Un dictado que
    /// llega mientras otro espera **hereda** esta foto: si fotografiara el
    /// portapapeles, guardaría el dictado anterior como si fuera de la
    /// persona.
    let foto: [ClipboardItemSnapshot]
    let marca: String
    let changeCount: Int
    let promesa: TextoPrometido
  }

  /// Escribe el dictado como promesa, marcado y sólo para este Mac.
  ///
  /// - Returns: el pendiente, o nil si la escritura no quedó como se pidió.
  static func escribirPromesa(
    _ texto: String,
    foto: [ClipboardItemSnapshot],
    en pasteboard: NSPasteboard,
    ahora: @escaping @Sendable () -> Duration
  ) -> PegadoPendiente? {
    let marca = UUID().uuidString
    let promesa = TextoPrometido(texto: texto, ahora: ahora)
    let item = NSPasteboardItem()
    item.setString(marca, forType: tipoDeLaMarca)
    // Lo que se pega y se va no es algo que la persona copió: un gestor de
    // portapapeles que respeta la convención no lo guarda, y no lee la
    // promesa antes del ⌘V.
    for tipo in transientTypes {
      item.setData(Data(), forType: tipo)
    }
    guard item.setDataProvider(promesa, forTypes: [.string]) else { return nil }

    // `.currentHostOnly`: el dictado no viaja al Portapapeles Universal del
    // iPhone ni de otro Mac. Limpia y deja listo en una sola llamada.
    pasteboard.prepareForNewContents(with: .currentHostOnly)
    guard pasteboard.writeObjects([item]) else { return nil }
    let pendiente = PegadoPendiente(
      foto: foto,
      marca: marca,
      changeCount: pasteboard.changeCount,
      promesa: promesa
    )
    return esDeDilo(pendiente, en: pasteboard) ? pendiente : nil
  }

  /// Si el portapapeles sigue teniendo **este** dictado y nada encima.
  ///
  /// Leer la marca no dispara la promesa: es otro tipo, con sus datos de
  /// verdad.
  static func esDeDilo(_ pendiente: PegadoPendiente, en pasteboard: NSPasteboard) -> Bool {
    pasteboard.changeCount == pendiente.changeCount
      && pasteboard.string(forType: tipoDeLaMarca) == pendiente.marca
  }

  /// Devuelve lo que había, sólo si el portapapeles sigue siendo de Dilo.
  ///
  /// Si la escritura de la foto falla, vuelve a dejar el dictado: el
  /// portapapeles nunca queda vacío por culpa de Dilo.
  static func devolver(
    _ pendiente: PegadoPendiente,
    en pasteboard: NSPasteboard,
    motivo: MotivoDeDevolucion
  ) -> MotivoDeDevolucion {
    guard esDeDilo(pendiente, en: pasteboard) else { return .ajeno }
    pendiente.promesa.detener()
    pasteboard.clearContents()
    guard !pendiente.foto.isEmpty else { return motivo }

    let items = pendiente.foto.map { foto in
      let item = NSPasteboardItem()
      for entrada in foto.entries {
        item.setData(entrada.data, forType: entrada.type)
      }
      return item
    }
    guard pasteboard.writeObjects(items) else {
      pasteboard.clearContents()
      pasteboard.setString(pendiente.promesa.texto, forType: .string)
      return .fallidoQuedoElDictado
    }
    return motivo
  }

  /// Convierte la promesa en texto de verdad. Al cerrar Dilo, porque una
  /// promesa cuyo dueño murió no entrega nada; y en «Pegar y copiar», donde
  /// el dictado tiene que quedarse como cualquier copia.
  static func materializar(_ pendiente: PegadoPendiente, en pasteboard: NSPasteboard) {
    guard esDeDilo(pendiente, en: pasteboard) else { return }
    pendiente.promesa.detener()
    pasteboard.clearContents()
    pasteboard.setString(pendiente.promesa.texto, forType: .string)
  }

  /// Hasta dónde se fotografía un portapapeles antes de pegar.
  struct TopesDeLaFoto: Equatable, Sendable {
    var bytes = 64 * 1_024 * 1_024
    var items = 128
    var tipos = 1_024

    static let deFabrica = TopesDeLaFoto()
  }

  /// Lo que salió de fotografiar el portapapeles.
  enum Foto: Sendable {
    case completa([ClipboardItemSnapshot])
    /// Un tipo anunciado no entregó datos: devolverla a medias corrompe.
    case incompleta
    /// Más grande que los topes: una imagen o un video que alguien copió.
    /// No se toca, y el dictado se queda en la tarjeta.
    case excedida
    /// El portapapeles cambió mientras se leía.
    case cambio

    /// Lo que espera `readClipboardItems`: los ítems, o nil para todo lo que
    /// no se puede devolver entero.
    var items: [ClipboardItemSnapshot]? {
      if case let .completa(items) = self { return items }
      return nil
    }
  }

  /// Igual que `snapshot(of:)`, todo o nada, pero con topes y mirando
  /// `changeCount` después de cada tipo. Cuenta ítems y tipos **antes** de
  /// leer un byte: una imagen de 200 MB se leía entera, se comía el plazo de
  /// 600 ms y el dictado no se pegaba.
  static nonisolated func foto(
    de pasteboard: NSPasteboard,
    topes: TopesDeLaFoto = .deFabrica
  ) -> Foto {
    let inicio = pasteboard.changeCount
    guard let items = pasteboard.pasteboardItems else { return .incompleta }
    guard items.count <= topes.items else { return .excedida }
    guard items.reduce(0, { $0 + $1.types.count }) <= topes.tipos else { return .excedida }

    var bytes = 0
    var fotos: [ClipboardItemSnapshot] = []
    fotos.reserveCapacity(items.count)
    for item in items {
      var entradas: [ClipboardItemSnapshot.Entry] = []
      for tipo in item.types {
        guard let datos = item.data(forType: tipo) else { return .incompleta }
        guard pasteboard.changeCount == inicio else { return .cambio }
        bytes += datos.count
        guard bytes <= topes.bytes else { return .excedida }
        entradas.append(ClipboardItemSnapshot.Entry(type: tipo, data: datos))
      }
      fotos.append(ClipboardItemSnapshot(entries: entradas))
    }
    return .completa(fotos)
  }
}
