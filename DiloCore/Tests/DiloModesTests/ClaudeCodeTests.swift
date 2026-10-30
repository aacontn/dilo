import Foundation
import Testing

@testable import DiloModes

/// Claude Code por voz, sin lanzar la CLI: las transcripciones de
/// `GrabacionesDeClaudeCode` son lo que escribió `claude` de verdad.
struct LectorDeClaudeCodeTests {
  private func leer(_ lineas: [String]) -> [MensajeDeClaudeCode] {
    lineas.flatMap(LectorDeClaudeCode.leer)
  }

  @Test func leeLosDosTurnosConPermisosEnOrden() {
    let mensajes = leer(GrabacionesDeClaudeCode.permitirYNegar)
    let sesion = "78e26841-aa02-42fe-82ea-2d9495a76d0a"
    let touch = EntradaDeHerramienta(
      json: #"{"command":"touch prueba.txt","description":"Create empty file prueba.txt in current folder"}"#,
      campos: ["command": "touch prueba.txt", "description": "Create empty file prueba.txt in current folder"]
    )
    #expect(mensajes.count == 12)
    #expect(mensajes[0] == .inicio(sesion: sesion, modelo: "claude-haiku-5-5"))
    #expect(mensajes[1] == .usaHerramienta(id: "toolu_016s8mJFX7bwYASZTUV97FRK", nombre: "Bash", entrada: touch))
    #expect(
      mensajes[2]
        == .pidePermiso(
          PedidoDePermiso(
            id: "c0457625-2640-4318-8870-7f8d5658895a",
            herramienta: "Bash",
            entrada: touch,
            usoID: "toolu_016s8mJFX7bwYASZTUV97FRK",
            rutaBloqueada: "/Volumes/SSD2/claude-code-pruebas/p1/prueba.txt",
            descripcionDeLaCLI: "Create empty file prueba.txt in current folder"
          )
        )
    )
    #expect(
      mensajes[3]
        == .terminoHerramienta(id: "toolu_016s8mJFX7bwYASZTUV97FRK", conError: false, contenido: "(Bash completed with no output)")
    )
    guard case .texto = mensajes[4], case let .fin(primero) = mensajes[5] else {
      Issue.record("el primer turno no terminó con texto y result")
      return
    }
    #expect(primero.falla == nil)
    #expect(primero.sesion == sesion)
    #expect(mensajes[9] == .terminoHerramienta(id: "toolu_01PY1Q5WDj6d8pZupWk6FgTt", conError: true, contenido: "La persona dijo que no."))
    // El bloque `thinking` vacío no dice nada.
    #expect(mensajes[10] == .texto("Me lo negaron: el `rm prueba.txt` fue rechazado, así que el archivo sigue ahí."))
  }

  @Test func ignoraLoQueNoEsJSONNiInteresa() {
    #expect(LectorDeClaudeCode.leer("").isEmpty)
    #expect(LectorDeClaudeCode.leer("No conversation found").isEmpty)
    #expect(LectorDeClaudeCode.leer(#"{"type":"rate_limit_event"}"#).isEmpty)
    #expect(LectorDeClaudeCode.leer(#"{"type":"system","subtype":"post_turn_summary"}"#).isEmpty)
  }

  @Test func loDeUnSubagenteNoSeDice() {
    let linea = #"{"type":"assistant","parent_tool_use_id":"toolu_1","message":{"content":[{"type":"text","text":"interno"}]}}"#
    #expect(LectorDeClaudeCode.leer(linea).isEmpty)
  }

  @Test func unPedidoQueNoEsPermisoSeContestaConError() {
    let linea = #"{"type":"control_request","request_id":"r9","request":{"subtype":"hook_callback","callback_id":"x"}}"#
    #expect(LectorDeClaudeCode.leer(linea) == [.pedidoDesconocido(id: "r9", tipo: "hook_callback")])
    #expect(LectorDeClaudeCode.leer(#"{"type":"control_cancel_request","request_id":"r9"}"#) == [.retiraPermiso(id: "r9")])
  }

  @Test func laRespuestaAInterrumpir() {
    #expect(
      LectorDeClaudeCode.leer(GrabacionesDeClaudeCode.interrumpida[4]) == [.respuestaDeControl(id: "req_int", error: nil)]
    )
  }
}

struct TraductorDeClaudeCodeTests {
  private func traducir(_ lineas: [String]) -> ([SalidaDelTurno], TraductorDeClaudeCode) {
    var traductor = TraductorDeClaudeCode(agente: "Claude Code")
    let salidas = lineas.flatMap(LectorDeClaudeCode.leer).flatMap { traductor.traducir($0) }
    return (salidas, traductor)
  }

  @Test func unPermisoAprobadoYOtroNegado() {
    let (salidas, traductor) = traducir(GrabacionesDeClaudeCode.permitirYNegar)
    #expect(traductor.sesion == "78e26841-aa02-42fe-82ea-2d9495a76d0a")
    #expect(salidas.count == 12)
    #expect(salidas[0] == .herramienta("Corriendo `touch prueba.txt`", enCurso: true))
    guard case let .pedirPermiso(pedido, descripcion, detalle) = salidas[1] else {
      Issue.record("no pidió permiso")
      return
    }
    #expect(pedido.herramienta == "Bash")
    #expect(descripcion == "Claude Code quiere correr `touch prueba.txt`")
    #expect(detalle.contains("touch prueba.txt"))
    #expect(detalle.contains("Para qué: Create empty file"))
    #expect(salidas[2] == .herramienta("Corriendo `touch prueba.txt`", enCurso: false))
    #expect(
      salidas[4]
        == .decir("Listo: ejecuté touch prueba.txt con la herramienta Bash en la carpeta de trabajo, y el comando terminó sin errores ni salida.")
    )
    #expect(salidas[5] == .fin(falla: nil, interrumpido: false))
    #expect(salidas.last == .fin(falla: nil, interrumpido: false))
  }

  @Test func elTurnoInterrumpidoNoEsFalla() {
    let (salidas, _) = traducir(GrabacionesDeClaudeCode.interrumpida)
    #expect(salidas.first == .fin(falla: nil, interrumpido: true))
    #expect(salidas.contains(.decir("cebolla.")))
    #expect(salidas.last == .fin(falla: nil, interrumpido: false))
  }

  @Test func retomarUnaSesionQueNoExisteEsFalla() {
    let (salidas, _) = traducir(GrabacionesDeClaudeCode.retomarUnaQueNoExiste)
    #expect(
      salidas == [.fin(falla: "No conversation found with session ID: 00000000-0000-4000-8000-000000000000", interrumpido: false)]
    )
  }

  @Test func unaHerramientaSinResultadoSeCierraAlTerminar() {
    var traductor = TraductorDeClaudeCode(agente: "Claude Code")
    _ = traductor.traducir(.usaHerramienta(id: "t1", nombre: "Read", entrada: EntradaDeHerramienta(json: "{}", campos: ["file_path": "/a/b/c.swift"])))
    let salidas = traductor.traducir(.fin(ResultadoDeClaudeCode(tipo: "success", conError: false)))
    #expect(salidas == [.herramienta("Leyendo c.swift", enCurso: false), .fin(falla: nil, interrumpido: false)])
  }

  @Test func unErrorDeLaAPIQueLlegaComoSuccess() {
    let resultado = ResultadoDeClaudeCode(tipo: "success", conError: true, texto: "API Error: 529 Overloaded")
    #expect(resultado.falla == "API Error: 529 Overloaded")
  }
}

struct EntradaParaClaudeCodeTests {
  private func objeto(_ linea: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(linea.utf8))) as? [String: Any] ?? [:]
  }

  @Test func elTurnoEsUnMensajeUserEnUnaLinea() {
    let linea = EntradaParaClaudeCode.turno("revisa los tests\ny dime")
    #expect(!linea.contains("\n"))
    #expect(
      linea == #"{"message":{"content":"revisa los tests\ny dime","role":"user"},"parent_tool_use_id":null,"session_id":"","type":"user"}"#
    )
  }

  @Test func permitirDevuelveLaEntradaTalCual() {
    let pedido = LectorDeClaudeCode.leer(GrabacionesDeClaudeCode.permitirYNegar[5])
    guard case let .pidePermiso(p) = pedido.first else {
      Issue.record("no hay pedido")
      return
    }
    let respuesta = objeto(EntradaParaClaudeCode.permitir(p))
    #expect(respuesta["type"] as? String == "control_response")
    let cuerpo = respuesta["response"] as? [String: Any]
    #expect(cuerpo?["subtype"] as? String == "success")
    #expect(cuerpo?["request_id"] as? String == "c0457625-2640-4318-8870-7f8d5658895a")
    let decision = cuerpo?["response"] as? [String: Any]
    #expect(decision?["behavior"] as? String == "allow")
    let entrada = decision?["updatedInput"] as? [String: Any]
    #expect(entrada?["command"] as? String == "touch prueba.txt")
  }

  @Test func negarLlevaElMotivo() {
    let p = PedidoDePermiso(id: "r1", herramienta: "Bash", entrada: .vacia)
    let decision = (objeto(EntradaParaClaudeCode.negar(p))["response"] as? [String: Any])?["response"] as? [String: Any]
    #expect(decision?["behavior"] as? String == "deny")
    #expect((decision?["message"] as? String)?.contains("dijo que no") == true)
  }

  @Test func interrumpirYContestarConError() {
    #expect(EntradaParaClaudeCode.interrumpir(id: "i1") == #"{"request":{"subtype":"interrupt"},"request_id":"i1","type":"control_request"}"#)
    let error = objeto(EntradaParaClaudeCode.errorDeControl(id: "r9", mensaje: "no"))["response"] as? [String: Any]
    #expect(error?["subtype"] as? String == "error")
    #expect(error?["request_id"] as? String == "r9")
  }
}

struct ArgumentosDeClaudeCodeTests {
  @Test func siemprePorProgramaYConPermisosALaMuesca() {
    let argumentos = ArgumentosDeClaudeCode.para(OpcionesDeClaudeCode())
    #expect(argumentos.starts(with: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]))
    #expect(argumentos.contains("--permission-prompt-tool"))
    #expect(argumentos[argumentos.firstIndex(of: "--permission-prompt-tool")! + 1] == "stdio")
    #expect(argumentos[argumentos.firstIndex(of: "--permission-mode")! + 1] == "manual")
    #expect(argumentos.contains("--append-system-prompt"))
  }

  @Test func nuncaUnModoQueApruebeSolo() {
    let todas: [OpcionesDeClaudeCode] = [
      OpcionesDeClaudeCode(),
      OpcionesDeClaudeCode(inicio: .laUltima, modelo: "opus", carpetasExtra: ["/x"]),
      OpcionesDeClaudeCode(inicio: .retomar(sesion: "abc"), modelo: "haiku", instrucciones: nil),
    ]
    for opciones in todas {
      #expect(Set(ArgumentosDeClaudeCode.para(opciones)).isDisjoint(with: ArgumentosDeClaudeCode.prohibidos))
    }
  }

  @Test func retomarYElegirModelo() {
    let ultima = ArgumentosDeClaudeCode.para(OpcionesDeClaudeCode(inicio: .laUltima))
    #expect(ultima.contains("--continue") && ultima.contains("--fork-session"))
    let misma = ArgumentosDeClaudeCode.para(OpcionesDeClaudeCode(inicio: .retomar(sesion: "abc"), modelo: " ", instrucciones: nil))
    #expect(misma.suffix(2) == ["--resume", "abc"])
    #expect(!misma.contains("--model"))
    #expect(!misma.contains("--fork-session"))
    let conModelo = ArgumentosDeClaudeCode.para(OpcionesDeClaudeCode(modelo: "sonnet", carpetasExtra: ["/a"], instrucciones: nil))
    #expect(conModelo.suffix(4) == ["--model", "sonnet", "--add-dir", "/a"])
  }
}

struct VozDeClaudeCodeTests {
  @Test func unBloqueDeCodigoNoSeLee() {
    let texto = """
      Arreglé el test. Quedó así:

      ```swift
      #expect(x == 1)
      ```

      Corre `swift test` para verlo.
      """
    #expect(
      VozDeClaudeCode.paraDecir(texto) == "Arreglé el test. Quedó así: Corre swift test para verlo. El detalle está en la transcripción."
    )
  }

  @Test func soloCodigoDiceDondeQuedo() {
    #expect(VozDeClaudeCode.paraDecir("```\nlet x = 1\n```") == "Te lo dejé en la transcripción.")
    #expect(VozDeClaudeCode.paraDecir("   \n") == nil)
  }

  @Test func rutasEnlacesYMarkdown() {
    let texto = """
      ## Cambios
      - Edité `/Volumes/SSD 1/Dilo/mac/Dilo/App/AppDelegate.swift`
      - **Ojo**: miré /Volumes/SSD2/dilo/Dilo/Conversacion/Destino.swift
      - Más en https://code.claude.com/docs/en/headless
      """
    #expect(
      VozDeClaudeCode.paraDecir(texto) == "Cambios. Edité AppDelegate.swift. Ojo: miré Destino.swift. Más en un enlace."
    )
  }

  @Test func unaTablaYUnDiffNoSeLeen() {
    let texto = """
      Resumen de tests:
      | Suite | Estado |
      |---|---|
      | A | ok |
      @@ -1,2 +1,2 @@
      Todo pasa.
      """
    #expect(VozDeClaudeCode.paraDecir(texto) == "Resumen de tests: Todo pasa. El detalle está en la transcripción.")
  }

  @Test func codigoEnLineaLargoEsEsto() {
    let texto = "Corre `xcodebuild -project Dilo.xcodeproj -scheme Dilo build CODE_SIGN_IDENTITY=-` y listo"
    #expect(VozDeClaudeCode.paraDecir(texto) == "Corre esto y listo. El detalle está en la transcripción.")
  }

  @Test func loLargoSeCortaEnUnaOracion() {
    let oracion = "Revisé el módulo de permisos y encontré un caso que faltaba cubrir en los tests. "
    let texto = String(repeating: oracion, count: 12)
    let dicho = VozDeClaudeCode.paraDecir(texto) ?? ""
    #expect(dicho.hasSuffix("cubrir en los tests. " + VozDeClaudeCode.avisoDeRecorte))
    #expect(dicho.count <= VozDeClaudeCode.topeParaDecir + VozDeClaudeCode.avisoDeRecorte.count + 1)
  }
}

struct PermisoDeClaudeCodeTests {
  private func pedido(_ herramienta: String, _ campos: [String: String], ruta: String? = nil) -> PedidoDePermiso {
    PedidoDePermiso(id: "r", herramienta: herramienta, entrada: EntradaDeHerramienta(objeto: campos), rutaBloqueada: ruta)
  }

  @Test func unaLineaPorHerramienta() {
    let casos: [(PedidoDePermiso, String)] = [
      (pedido("Bash", ["command": "swift test"]), "Claude Code quiere correr `swift test`"),
      (pedido("Edit", ["file_path": "/r/Dilo/App/AppDelegate.swift", "old_string": "a", "new_string": "b"]), "Claude Code quiere editar `AppDelegate.swift`"),
      (pedido("Write", ["file_path": "/r/docs/nuevo.md", "content": "hola"]), "Claude Code quiere escribir `nuevo.md`"),
      (pedido("WebFetch", ["url": "https://www.apple.com/macos"]), "Claude Code quiere abrir apple.com"),
      (pedido("mcp__switchboard__status", [:]), "Claude Code quiere usar `status` de switchboard"),
      (pedido("ExitPlanMode", ["plan": "x"]), "Claude Code quiere dejar de planear y empezar a cambiar archivos"),
      (pedido("Raro", [:]), "Claude Code quiere usar `Raro`"),
    ]
    for (p, esperado) in casos {
      #expect(PermisoDeClaudeCode.descripcion(p, agente: "Claude Code") == esperado)
    }
  }

  @Test func usaElNombreDelAgenteYCortaElComando() {
    let largo = pedido("Bash", ["command": String(repeating: "x", count: 100) + "\nsegunda"])
    let descripcion = PermisoDeClaudeCode.descripcion(largo, agente: "Código")
    #expect(descripcion.hasPrefix("Código quiere correr `xxxx"))
    #expect(descripcion.hasSuffix("…`"))
    #expect(PermisoDeClaudeCode.detalle(largo).contains("segunda"))
  }

  @Test func elDetalleDeUnaEdicion() {
    let p = pedido("Edit", ["file_path": "/r/a.swift", "old_string": "viejo", "new_string": "nuevo"], ruta: "/r/a.swift")
    #expect(PermisoDeClaudeCode.detalle(p) == "Archivo: /r/a.swift\nCambia:\nviejo\nPor:\nnuevo\nRuta: /r/a.swift")
  }

  @Test func laBarraNombraLaHerramienta() {
    #expect(HerramientaDeClaudeCode.enCurso("Grep", EntradaDeHerramienta(objeto: ["pattern": "TODO"])) == "Buscando «TODO»")
    #expect(HerramientaDeClaudeCode.enCurso("Bash", EntradaDeHerramienta(objeto: ["command": "git status\ngit diff"])) == "Corriendo `git status …`")
    #expect(HerramientaDeClaudeCode.enCurso("mcp__dilo__tus_palabras", .vacia) == "Usando tus_palabras de dilo")
  }
}

struct ProyectosDeClaudeCodeTests {
  private let proyectos = CatalogoDeProyectos.todos(
    propios: [ProyectoDeClaudeCode(nombre: "Dilo", carpeta: "/Volumes/SSD 1/Dilo/mac")],
    deDeveloper: CatalogoDeProyectos.deDeveloper(
      carpetas: [".claude", "dilo", "dilo-landing", "switchboard-os", "andes-flags-plataforma", "homera"],
      raiz: "/Users/x/Developer"
    )
  )

  @Test func loEscritoEnAjustesLeGanaAlDeDeveloper() {
    #expect(proyectos.map(\.nombre) == ["Dilo", "andes-flags-plataforma", "dilo-landing", "homera", "switchboard-os"])
    #expect(proyectos.first?.carpeta == "/Volumes/SSD 1/Dilo/mac")
  }

  private func entender(_ texto: String, esperando: Bool = false) -> PedidoAClaudeCode {
    PedidoAClaudeCode.entender(texto, proyectos: proyectos, esperandoProyecto: esperando)
  }

  @Test func enUnProyectoConComaYSinComa() {
    let conComa = entender("en Dilo, revisa los tests")
    #expect(conComa.proyecto?.carpeta == "/Volumes/SSD 1/Dilo/mac")
    #expect(conComa.tarea == "Revisa los tests")
    #expect(!conComa.retomar)
    #expect(entender("En dilo revisa los tests").tarea == "Revisa los tests")
    #expect(entender("en el proyecto homera: arregla el login").proyecto?.nombre == "homera")
  }

  @Test func elNombreMasLargoYElPrincipioDeUnNombre() {
    #expect(entender("en dilo landing, cambia el título").proyecto?.nombre == "dilo-landing")
    #expect(entender("en Dilo-landing cambia el título").tarea == "Cambia el título")
    #expect(entender("en switchboard, ¿qué falta?").proyecto?.nombre == "switchboard-os")
    #expect(entender("en Andes Flags, corre el build").proyecto?.nombre == "andes-flags-plataforma")
  }

  @Test func sinProyectoLaTareaEsTodo() {
    let pedido = entender("en general, revisa los tests")
    #expect(pedido.proyecto == nil)
    #expect(pedido.tarea == "en general, revisa los tests")
    #expect(entender("revisa los tests en dilo").proyecto == nil)
  }

  @Test func retomar() {
    let retoma = entender("retoma la sesión de Dilo")
    #expect(retoma.retomar)
    #expect(retoma.proyecto?.nombre == "Dilo")
    #expect(retoma.tarea.isEmpty)

    let conTarea = entender("Retoma la sesión del proyecto homera y corre los tests")
    #expect(conTarea.proyecto?.nombre == "homera")
    #expect(conTarea.tarea == "Corre los tests")

    let revisa = entender("Revisa Claude Code")
    #expect(revisa.retomar)
    #expect(revisa.proyecto == nil)
    #expect(revisa.tarea.isEmpty)

    #expect(entender("revisa cloud code en dilo").proyecto?.nombre == "Dilo")
    #expect(entender("retoma, y dime qué falta").tarea == "Dime qué falta")
  }

  @Test func laRespuestaALaPregunta() {
    let respuesta = entender("Homera.", esperando: true)
    #expect(respuesta.proyecto?.nombre == "homera")
    #expect(respuesta.tarea.isEmpty)
    #expect(entender("Homera.").proyecto == nil)
  }

  @Test func laPregunta() {
    #expect(PreguntaDeProyecto.texto(proyectos: proyectos) == "¿En qué proyecto? Por ejemplo, dilo, andes flags plataforma o dilo landing.")
    #expect(PreguntaDeProyecto.texto(proyectos: []).hasPrefix("No tengo proyectos"))
  }
}

struct UbicacionDeClaudeTests {
  @Test func loElegidoPrimeroYDespuesLosInstaladores() {
    let lista = UbicacionDeClaude.candidatos(home: "/Users/x", elegida: "~/bin/claude")
    #expect(lista.first == "/Users/x/bin/claude")
    #expect(lista.contains("/Users/x/.local/bin/claude"))
    #expect(!lista.contains { $0.contains("/.claude/") })
    #expect(UbicacionDeClaude.candidatos(home: "/Users/x", elegida: " ").first == "/Users/x/.local/bin/claude")
  }

  @Test func elPathSumaLoQueFalta() {
    #expect(
      UbicacionDeClaude.path(home: "/Users/x", actual: "/usr/bin:/bin:/opt/homebrew/bin")
        == "/Users/x/.local/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
    )
  }

  @Test func laSesionDeLaCLI() {
    #expect(UbicacionDeClaude.haySesion(json: #"{"loggedIn": true, "authMethod": "claude.ai"}"#, codigoDeSalida: 0) == true)
    #expect(UbicacionDeClaude.haySesion(json: #"{"loggedIn": false, "authMethod": "none"}"#, codigoDeSalida: 1) == false)
    #expect(UbicacionDeClaude.haySesion(json: "Not logged in", codigoDeSalida: 1) == false)
    #expect(UbicacionDeClaude.haySesion(json: "", codigoDeSalida: 2) == nil)
  }

  @Test func elDetalleDeStderrEsLaUltimaLinea() {
    #expect(
      FallaDeClaudeCode.detalle(deStderr: "warn: algo\nNo conversation found with session ID: x\n\n")
        == "No conversation found with session ID: x"
    )
    #expect(FallaDeClaudeCode.sinSesion.errorDescription?.contains("claude") == true)
  }
}
