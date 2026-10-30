import AppIntents
import DiloModes
import DiloPlataforma
import Foundation
import Testing

@testable import Dilo

/// Los App Intents sin Atajos ni Siri: lo que hace cada uno se prueba con un
/// doble de la app (`AccionesParaAtajos`), sin micrófono, sin portapapeles y
/// sin el puente global.
@MainActor
@Suite("Atajos de Dilo")
struct AtajosDeDiloTests {
  @MainActor
  final class AppDeMentira: AccionesParaAtajos {
    var pedidos: [DirectDictationController.ModoPedido] = []
    var respuesta: DirectDictationController.RespuestaAlDictar = .empezo
    var notas = 0
    var modos: [Modo] = [
      Modo(id: "correo", nombre: "Correo", prompt: ""),
      Modo(id: "codigo", nombre: "Código", prompt: ""),
    ]
    var modoDelAtajoGeneral: String? = "correo"
    var ultimoDictado: UltimoDictado?
    var copiados: [String] = []
    var historialEncendido = true
    var historial: [String] = []
    var avisos: [AvisoDeAfuera] = []

    func dictar(_ pedido: DirectDictationController.ModoPedido) -> DirectDictationController.RespuestaAlDictar {
      pedidos.append(pedido)
      return respuesta
    }
    func dictarNota() { notas += 1 }
    func copiar(_ texto: String) { copiados.append(texto) }
    func buscarEnHistorial(_ consulta: String) async throws -> [String] {
      historial.filter { consulta.isEmpty || $0.contains(consulta) }
    }
    func transcribir(_ archivo: URL) async throws -> String { archivo.lastPathComponent }
    func mostrarEnLaMuesca(_ aviso: AvisoDeAfuera) { avisos.append(aviso) }
    var conversando = false
    func conversar() -> Bool {
      conversando.toggle()
      return conversando
    }
  }

  /// «Conversar con Dilo» llama y, corrido otra vez, cuelga.
  @Test func conversarLlamaYCuelga() {
    let app = AppDeMentira()
    #expect(EjecucionDeAtajos.conversar(app))
    #expect(!EjecucionDeAtajos.conversar(app))
  }

  /// En el host de los tests `AppDelegate` no arranca, así que el puente
  /// está vacío: un atajo que llega mientras Dilo arranca dice que esperes.
  @Test func sinAppLevantadaDiceQueEsperes() {
    #expect(throws: FallaDeAtajo.diloNoEstaListo) { try PuenteDeAtajos.requerido() }
  }

  @Test func dictarPideElModoQueCorresponde() throws {
    let app = AppDeMentira()
    _ = try EjecucionDeAtajos.dictar(app, modo: nil)
    _ = try EjecucionDeAtajos.dictar(app, modo: .sinModo)
    _ = try EjecucionDeAtajos.dictar(app, modo: ModoDeDilo(id: "codigo", nombre: "Código"))
    #expect(app.pedidos == [.elDelAtajoGeneral, .ninguno, .modo("codigo")])
  }

  @Test func dictarConUnModoBorradoLoDice() {
    let app = AppDeMentira()
    app.respuesta = .modoDesconocido
    #expect(throws: FallaDeAtajo.modoDesconocido) {
      try EjecucionDeAtajos.dictar(app, modo: ModoDeDilo(id: "x", nombre: "X"))
    }
  }

  @Test func losModosEmpiezanConSinModo() {
    let modos = EjecucionDeAtajos.modos(AppDeMentira())
    #expect(modos.map(\.id) == [ModoDeDilo.idSinModo, "correo", "codigo"])
    #expect(EjecucionDeAtajos.modos(nil).map(\.id) == [ModoDeDilo.idSinModo])
  }

  /// Como se dice: «codigo» encuentra «Código».
  @Test func buscarUnModoNoMiraTildesNiMayusculas() {
    #expect(EjecucionDeAtajos.modos(AppDeMentira(), que: "CODIGO").map(\.id) == ["codigo"])
    #expect(EjecucionDeAtajos.modos(AppDeMentira(), que: " ").count == 3)
  }

  @Test func elegirModoEsLoMismoQueElPanel() throws {
    let app = AppDeMentira()
    #expect(try EjecucionDeAtajos.elegirModo(app, ModoDeDilo(id: "codigo", nombre: "?")) == "Código")
    #expect(app.modoDelAtajoGeneral == "codigo")
    #expect(try EjecucionDeAtajos.elegirModo(app, .sinModo) == nil)
    #expect(app.modoDelAtajoGeneral == nil)
  }

  @Test func elegirUnModoQueNoExisteNoTocaNada() {
    let app = AppDeMentira()
    #expect(throws: FallaDeAtajo.modoDesconocido) {
      try EjecucionDeAtajos.elegirModo(app, ModoDeDilo(id: "borrado", nombre: "Borrado"))
    }
    #expect(app.modoDelAtajoGeneral == "correo")
  }

  @Test func sinDictadoLoDiceEnVezDeDevolverVacio() {
    let app = AppDeMentira()
    #expect(throws: FallaDeAtajo.sinDictado) { try EjecucionDeAtajos.ultimoDictado(app, mitad: .entregado) }
    #expect(throws: FallaDeAtajo.sinDictado) { try EjecucionDeAtajos.copiarUltimo(app, mitad: .entregado) }
    #expect(app.copiados.isEmpty)
  }

  @Test func elUltimoDictadoDevuelveLaMitadPedida() throws {
    let app = AppDeMentira()
    app.ultimoDictado = UltimoDictado(original: "eh hola", limpio: "hola", transformado: "Hola.")
    #expect(try EjecucionDeAtajos.ultimoDictado(app, mitad: .entregado) == "Hola.")
    #expect(try EjecucionDeAtajos.ultimoDictado(app, mitad: .original) == "eh hola")
    #expect(try EjecucionDeAtajos.copiarUltimo(app, mitad: .entregado) == "Hola.")
    #expect(app.copiados == ["Hola."])
  }

  @Test func buscarConElHistorialApagadoDiceComoPrenderlo() async {
    let app = AppDeMentira()
    app.historialEncendido = false
    await #expect(throws: FallaDeAtajo.historialApagado) {
      try await EjecucionDeAtajos.buscar(app, consulta: "", maximo: 5)
    }
  }

  @Test func buscarRespetaElMaximo() async throws {
    let app = AppDeMentira()
    app.historial = (1...80).map { "dictado \($0)" }
    #expect(try await EjecucionDeAtajos.buscar(app, consulta: "", maximo: 3) == ["dictado 1", "dictado 2", "dictado 3"])
    #expect(try await EjecucionDeAtajos.buscar(app, consulta: "", maximo: 500).count == EjecucionDeAtajos.maximoDeResultados)
    #expect(try await EjecucionDeAtajos.buscar(app, consulta: "", maximo: 0).count == 1)
  }

  @Test func mostrarEnLaMuescaLimpiaLoQueLlega() throws {
    let app = AppDeMentira()
    try EjecucionDeAtajos.mostrar(app, texto: "Compilación\nlista", simbolo: "nada", segundos: 500) { _ in false }
    #expect(app.avisos.first?.texto == "Compilación lista")
    #expect(app.avisos.first?.simbolo == AvisoDeAfuera.simboloPorDefecto)
    #expect(app.avisos.first?.segundos == 120)
    #expect(throws: FallaDeAtajo.textoVacio) {
      try EjecucionDeAtajos.mostrar(app, texto: "  ", simbolo: nil, segundos: nil) { _ in true }
    }
  }

  /// Los bytes de un atajo se escriben a un temporal y se borran al
  /// terminar, aunque la transcripción falle.
  @Test func unArchivoSinRutaPasaPorUnTemporalQueSeBorra() async throws {
    let carpeta = FileManager.default.temporaryDirectory.appending(path: "dilo-atajos-\(UUID())")
    try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: carpeta) }
    let archivo = IntentFile(data: Data("audio".utf8), filename: "nota.wav")

    var visto: URL?
    let leido = try await EjecucionDeAtajos.conArchivo(archivo, temporales: carpeta) { url in
      visto = url
      return try String(contentsOf: url, encoding: .utf8)
    }
    #expect(leido == "audio")
    #expect(visto?.pathExtension == "wav")
    #expect(try FileManager.default.contentsOfDirectory(atPath: carpeta.path(percentEncoded: false)).isEmpty)

    struct Falla: Error {}
    await #expect(throws: Falla.self) {
      try await EjecucionDeAtajos.conArchivo(archivo, temporales: carpeta) { _ in throw Falla() }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: carpeta.path(percentEncoded: false)).isEmpty)
  }

  /// Un archivo con ruta se lee ahí mismo: un video de un giga no se copia.
  @Test func unArchivoConRutaSeUsaDondeEsta() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "dilo-atajos-\(UUID()).m4a")
    try Data("x".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let usada = try await EjecucionDeAtajos.conArchivo(IntentFile(fileURL: url)) { $0 }
    #expect(usada.standardizedFileURL == url.standardizedFileURL)
  }

  /// Los App Shortcuts nombran la app en cada frase y no pasan del tope
  /// de diez que pone el sistema.
  @Test func losAtajosNoPasanDelTope() {
    #expect(AtajosDeDilo.appShortcuts.count <= 10)
  }
}
