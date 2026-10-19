import Foundation
import Synchronization
import Testing

@testable import DiloModes

/// Lo que congelaba Ajustes era preguntar al Llavero una y otra vez desde el
/// hilo principal. Estas pruebas cuentan las preguntas: abrir la ventana y
/// pasar por las secciones que quieren saber si hay clave es **una** lectura
/// por cuenta, no una por vista ni por evaluación del `body`.
@MainActor
struct ClavesDeLosProveedoresTests {
  /// Un almacén que cuenta lo que le piden, con una demora para que las
  /// preguntas simultáneas de verdad se crucen.
  final class AlmacenQueCuenta: AlmacenDeClaves, Sendable {
    private let estado: Mutex<(claves: [String: String], lecturas: Int, escrituras: Int)>
    let demora: Duration

    init(_ claves: [String: String] = [:], demora: Duration = .milliseconds(30)) {
      estado = Mutex((claves, 0, 0))
      self.demora = demora
    }

    var lecturas: Int { estado.withLock { $0.lecturas } }
    var escrituras: Int { estado.withLock { $0.escrituras } }

    func clave(para cuenta: String) -> String? {
      Issue.record("nadie debería traer el secreto para saber si existe")
      return estado.withLock { $0.claves[cuenta] }
    }

    func tieneClave(para cuenta: String) -> Bool {
      #expect(!Thread.isMainThread, "el Llavero no se consulta en el hilo principal")
      Thread.sleep(forTimeInterval: Double(demora.components.attoseconds) / 1e18)
      return estado.withLock {
        $0.lecturas += 1
        return $0.claves[cuenta] != nil
      }
    }

    func guardar(_ clave: String, para cuenta: String) throws {
      #expect(!Thread.isMainThread)
      estado.withLock {
        $0.escrituras += 1
        $0.claves[cuenta] = clave
      }
    }

    func borrar(_ cuenta: String) throws {
      #expect(!Thread.isMainThread)
      estado.withLock {
        $0.escrituras += 1
        $0.claves[cuenta] = nil
      }
    }

    func guardada(_ cuenta: String) -> String? { estado.withLock { $0.claves[cuenta] } }
  }

  let cuenta = Proveedor.deFabrica.proveedor("anthropic")!.cuentaEnElLlavero

  @Test func abrirLaSeccionEsUnaLecturaNoN() async {
    let almacen = AlmacenQueCuenta([cuenta: "sk-prueba"])
    let claves = ClavesDeLosProveedores(almacen: almacen)

    // Inicio, Claude, Idioma y Tus palabras preguntan casi a la vez.
    async let a = claves.mirar(cuenta)
    async let b = claves.mirar(cuenta)
    async let c = claves.mirar(cuenta)
    async let d = claves.mirar(cuenta)
    let respuestas = await [a, b, c, d]

    #expect(respuestas == [true, true, true, true])
    #expect(almacen.lecturas == 1)

    // Y redibujar cien veces no vuelve a preguntar.
    for _ in 0..<100 { _ = claves.hay(cuenta) }
    await claves.mirar(cuenta)
    #expect(almacen.lecturas == 1)
    #expect(claves.estado(de: cuenta) == .hay)
  }

  @Test func sinMirarNoSeLeeNada() {
    let almacen = AlmacenQueCuenta([cuenta: "sk-prueba"])
    let claves = ClavesDeLosProveedores(almacen: almacen)
    #expect(!claves.hay(cuenta))
    #expect(claves.estado(de: cuenta) == .sinLeer)
    #expect(almacen.lecturas == 0)
  }

  @Test func guardarEsUnaEscrituraYNoPideLeerDeNuevo() async throws {
    let almacen = AlmacenQueCuenta()
    let claves = ClavesDeLosProveedores(almacen: almacen)
    #expect(await claves.mirar(cuenta) == false)

    try await claves.guardar("  sk-nueva \n", para: cuenta)
    #expect(almacen.escrituras == 1)
    #expect(almacen.guardada(cuenta) == "sk-nueva")
    #expect(claves.estado(de: cuenta) == .hay)
    await claves.mirar(cuenta)
    #expect(almacen.lecturas == 1)
  }

  @Test func guardarEnBlancoBorra() async throws {
    let almacen = AlmacenQueCuenta([cuenta: "sk-vieja"])
    let claves = ClavesDeLosProveedores(almacen: almacen)
    try await claves.guardar("   ", para: cuenta)
    #expect(almacen.guardada(cuenta) == nil)
    #expect(claves.estado(de: cuenta) == .falta)
  }

  @Test func olvidarVuelveALeerUnaVez() async {
    let almacen = AlmacenQueCuenta([cuenta: "sk"])
    let claves = ClavesDeLosProveedores(almacen: almacen)
    await claves.mirar(cuenta)
    claves.olvidar()
    #expect(claves.estado(de: cuenta) == .sinLeer)
    await claves.mirar(cuenta)
    await claves.mirar(cuenta)
    #expect(almacen.lecturas == 2)
  }

  @Test func cadaCuentaSeLeePorSuCuenta() async {
    let almacen = AlmacenQueCuenta([cuenta: "sk"])
    let claves = ClavesDeLosProveedores(almacen: almacen)
    let otra = Proveedor.deFabrica.proveedor("openai")!.cuentaEnElLlavero
    #expect(await claves.mirar(cuenta))
    #expect(await claves.mirar(otra) == false)
    #expect(almacen.lecturas == 2)
  }

  @Test func loGuardadoMientrasSeLeeGana() async throws {
    let almacen = AlmacenQueCuenta(demora: .milliseconds(80))
    let claves = ClavesDeLosProveedores(almacen: almacen)
    async let lectura = claves.mirar(cuenta)
    try await Task.sleep(for: .milliseconds(10))
    try await claves.guardar("sk-nueva", para: cuenta)
    _ = await lectura
    #expect(claves.estado(de: cuenta) == .hay)
  }

  @Test func fijarNoTocaElAlmacen() {
    let almacen = AlmacenQueCuenta()
    let claves = ClavesDeLosProveedores(almacen: almacen)
    claves.fijar(true, para: cuenta)
    #expect(claves.hay(cuenta))
    #expect(almacen.lecturas == 0 && almacen.escrituras == 0)
  }
}

extension ClavesDeLosProveedoresTests {
  /// «Probar conexión» trae el secreto una vez, fuera del hilo principal,
  /// y sin cambiar lo que se sabe de la cuenta.
  @Test func elSecretoSeTraeSoloAlPedirlo() async {
    let almacen = AlmacenQueExigeOtroHilo(["c": "sk"])
    let claves = ClavesDeLosProveedores(almacen: almacen)
    #expect(await claves.secreto("c") == "sk")
    #expect(claves.estado(de: "c") == .sinLeer)
  }
}

/// Un almacén en memoria que verifica que el secreto se pide fuera del
/// hilo principal.
final class AlmacenQueExigeOtroHilo: AlmacenDeClaves, Sendable {
  let claves: [String: String]
  init(_ claves: [String: String]) { self.claves = claves }
  func clave(para cuenta: String) -> String? {
    #expect(!Thread.isMainThread)
    return claves[cuenta]
  }
  func guardar(_ clave: String, para cuenta: String) throws {}
  func borrar(_ cuenta: String) throws {}
}
