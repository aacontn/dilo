import Testing

@testable import DiloCapabilities

/// La regla de qué impide dictar y en qué orden se dice. Cada caso arma la
/// foto que quiere: nada de esto toca el sistema.
struct EstadoParaDictarTests {
  /// Todo en orden: es la foto de la que parte cada caso.
  private static let todoListo = EstadoParaDictar(
    permisos: .todosConcedidos,
    pideReconocimientoDeVoz: true,
    admitePegadoDirecto: true,
    accesibilidad: true,
    motor: .listo,
    campoEsSeguro: false,
    traduccion: .noAplica
  )

  private func con(_ cambio: (inout EstadoParaDictar) -> Void) -> EstadoParaDictar {
    var estado = Self.todoListo
    cambio(&estado)
    return estado
  }

  @Test func todoListoNoBloquea() {
    #expect(Self.todoListo.bloqueos.isEmpty)
    #expect(Self.todoListo.primerBloqueo == nil)
  }

  @Test(arguments: [
    (EstadoParaDictar.Autorizacion.denegada, BloqueoDelDictado.microfonoDenegado),
    (.sinDecidir, .microfonoSinDecidir),
  ])
  func elMicrofonoSinPermiso(autorizacion: EstadoParaDictar.Autorizacion, bloqueo: BloqueoDelDictado) {
    let estado = con { $0.permisos.microfono = autorizacion }
    #expect(estado.bloqueos == [bloqueo])
    #expect(bloqueo.permiso == .microfono)
  }

  /// Sin entrada de audio se dice eso y no «falta el permiso»: el permiso
  /// está, lo que falta es enchufar algo.
  @Test func sinNingunMicrofonoConectado() {
    let estado = con { $0.permisos.hayMicrofono = false }
    #expect(estado.bloqueos == [.sinMicrofono])
    #expect(BloqueoDelDictado.sinMicrofono.permiso == nil)
  }

  /// Con el permiso denegado no hay forma de saber si hay micrófono, y decir
  /// los dos sería pedirle a la persona dos arreglos por uno.
  @Test func sinPermisoNoSeDiceTambienQueNoHayMicrofono() {
    let estado = con {
      $0.permisos.microfono = .denegada
      $0.permisos.hayMicrofono = false
    }
    #expect(estado.bloqueos == [.microfonoDenegado])
  }

  @Test func reconocimientoDeVozDenegado() {
    let estado = con { $0.permisos.reconocimientoDeVoz = .denegada }
    #expect(estado.bloqueos == [.reconocimientoDeVozDenegado])
  }

  /// El día que un motor prepare sin ese permiso, su falta no bloquea.
  @Test func unMotorQueNoPideReconocimientoDeVozNoSeBloqueaPorEl() {
    let estado = con {
      $0.pideReconocimientoDeVoz = false
      $0.permisos.reconocimientoDeVoz = .denegada
    }
    #expect(estado.bloqueos.isEmpty)
  }

  @Test func sinAccesibilidad() {
    let estado = con { $0.accesibilidad = false }
    #expect(estado.bloqueos == [.sinAccesibilidad])
  }

  /// Lo que el anfitrión esconde no se pide: sin pegado directo,
  /// Accesibilidad no sirve de nada y no puede impedir dictar.
  @Test func unAnfitrionSinPegadoDirectoNoPideAccesibilidad() {
    let estado = con {
      $0.admitePegadoDirecto = false
      $0.accesibilidad = false
    }
    #expect(estado.bloqueos.isEmpty)
  }

  @Test func elMotorQueTodaviaNoEstaListo() {
    #expect(con { $0.motor = .preparando }.bloqueos == [.preparandoMotor])
    #expect(
      con { $0.motor = .bajandoModelo(idioma: "Español", porcentaje: 40) }.bloqueos
        == [.bajandoModelo(idioma: "Español", porcentaje: 40)]
    )
    #expect(con { $0.motor = .fallo("sin disco") }.bloqueos == [.motorFallo("sin disco")])
    #expect(BloqueoDelDictado.preparandoMotor.seResuelveSolo)
    #expect(!BloqueoDelDictado.motorFallo("x").seResuelveSolo)
  }

  /// Un motor detenido por un permiso no suma un segundo bloqueo: el del
  /// permiso ya lo dice.
  @Test func elMotorEsperandoUnPermisoNoSeRepite() {
    let estado = con {
      $0.permisos.microfono = .denegada
      $0.motor = .esperandoPermiso
    }
    #expect(estado.bloqueos == [.microfonoDenegado])
  }

  @Test func campoProtegidoYTraduccion() {
    #expect(con { $0.campoEsSeguro = true }.bloqueos == [.campoProtegido])
    #expect(con { $0.traduccion = .sinIdioma }.bloqueos == [.traduccionSinIdioma])
    #expect(con { $0.traduccion = .noLista }.bloqueos == [.traduccionNoLista])
    #expect(con { $0.traduccion = .lista }.bloqueos.isEmpty)
  }

  /// El orden es el de resolverlos: micrófono, voz, Accesibilidad, motor,
  /// campo, traducción. La muesca dice el primero.
  @Test func variosALaVezSeDicenEnElOrdenDeResolverlos() {
    let estado = EstadoParaDictar(
      permisos: PermisosLeidos(microfono: .sinDecidir, hayMicrofono: true, reconocimientoDeVoz: .denegada),
      pideReconocimientoDeVoz: true,
      admitePegadoDirecto: true,
      accesibilidad: false,
      motor: .preparando,
      campoEsSeguro: true,
      traduccion: .noLista
    )
    #expect(estado.bloqueos == [
      .microfonoSinDecidir, .reconocimientoDeVozDenegado, .sinAccesibilidad,
      .preparandoMotor, .campoProtegido, .traduccionNoLista,
    ])
    #expect(estado.primerBloqueo == .microfonoSinDecidir)
  }

  /// El log nunca lleva el porqué del sistema: puede traer una ruta.
  @Test func elNombreEnElLogNoLlevaElPorque() {
    #expect(BloqueoDelDictado.motorFallo("/Users/alguien/x").nombreEnElLog == "motorFallo")
  }
}
