import Foundation
import Testing

@testable import DiloModes

struct ResolucionDeProveedorTests {
  private let catalogo: [Proveedor] = [
    Proveedor(id: "chip", nombre: "El modelo de Apple", dialecto: .enElChip),
    Proveedor(
      id: "gemini", nombre: "Google Gemini", dialecto: .gemini,
      urlBase: URL(string: "https://generativelanguage.googleapis.com/v1beta"),
      modelo: "gemini-2.5-flash"
    ),
    Proveedor(
      id: "openai", nombre: "OpenAI", dialecto: .compatibleOpenAI,
      urlBase: URL(string: "https://api.openai.com/v1"), modelo: ""
    ),
    Proveedor(
      id: "propio", nombre: "El tuyo", dialecto: .compatibleOpenAI,
      urlBase: URL(string: "http://localhost:11434/v1"), modelo: "llama3"
    ),
  ]

  private func conClaves(_ ids: Set<String>) -> (Proveedor) -> Bool {
    { ids.contains($0.id) }
  }

  @Test func sinProveedorPropioHeredaElGeneral() {
    let modo = Modo(id: "limpio", nombre: "Limpio", prompt: "")
    let plan = ResolucionDeProveedor.plan(
      para: modo, general: "gemini", catalogo: catalogo,
      tieneClave: conClaves(["gemini"])
    )
    #expect(plan.primario?.proveedor.id == "gemini")
    #expect(plan.respaldo == nil)
    #expect(!plan.avisaCruceALaNube)
  }

  @Test func unProveedorSinModeloNoEstaDisponible() {
    // Los ajustes de fábrica dejan el modelo vacío: sin este corte, un
    // dictado terminaba en un POST a api.openai.com sin modelo ni clave.
    let modo = Modo(id: "correo", nombre: "Correo", prompt: "", proveedorID: "openai")
    let plan = ResolucionDeProveedor.plan(
      para: modo, general: "gemini", catalogo: catalogo,
      tieneClave: conClaves(["openai", "gemini"])
    )
    #expect(plan.primario?.proveedor.id == "gemini")
  }

  @Test func unProveedorBorradoHeredaEnSilencio() {
    let modo = Modo(id: "correo", nombre: "Correo", prompt: "", proveedorID: "el-que-borre")
    let plan = ResolucionDeProveedor.plan(
      para: modo, general: "chip", catalogo: catalogo, tieneClave: conClaves([])
    )
    #expect(plan.primario?.proveedor.id == "chip")
    #expect(!plan.avisaCruceALaNube)
  }

  @Test func elModoLocalQueCaeALaNubeAvisa() {
    let modo = Modo(id: "codigo", nombre: "Código", prompt: "", proveedorID: "propio")
    let plan = ResolucionDeProveedor.plan(
      para: modo, general: "gemini", catalogo: catalogo,
      tieneClave: conClaves(["gemini"])
    )
    #expect(plan.primario?.proveedor.id == "propio")
    #expect(plan.respaldo?.proveedor.id == "gemini")
    #expect(plan.avisaCruceALaNube)
  }

  @Test func elModoLocalQueNiSiquieraResuelveTambienAvisa() {
    // El pendiente conocido del spec: "era local" se deduce del id que el modo
    // pidió, no de una resolución que acá está vacía.
    var propioSinModelo = catalogo
    propioSinModelo[3].modelo = ""
    let modo = Modo(id: "codigo", nombre: "Código", prompt: "", proveedorID: "propio")
    let plan = ResolucionDeProveedor.plan(
      para: modo, general: "gemini", catalogo: propioSinModelo,
      tieneClave: conClaves(["gemini"])
    )
    #expect(plan.primario?.proveedor.id == "gemini")
    #expect(plan.avisaCruceALaNube)
  }

  @Test func noSeReintentaLaMismaLlamadaDosVeces() {
    let modo = Modo(id: "correo", nombre: "Correo", prompt: "", proveedorID: "gemini")
    let plan = ResolucionDeProveedor.plan(
      para: modo, general: "gemini", catalogo: catalogo,
      tieneClave: conClaves(["gemini"])
    )
    #expect(plan.respaldo == nil)
  }

  @Test func mismoProveedorConOtroModeloSiMereceLaCaida() {
    var conDosModelos = catalogo
    conDosModelos.append(
      Proveedor(
        id: "gemini-pro", nombre: "Google Gemini", dialecto: .gemini,
        urlBase: URL(string: "https://generativelanguage.googleapis.com/v1beta"),
        modelo: "gemini-2.5-pro"
      )
    )
    let modo = Modo(id: "correo", nombre: "Correo", prompt: "", proveedorID: "gemini-pro")
    let plan = ResolucionDeProveedor.plan(
      para: modo, general: "gemini", catalogo: conDosModelos,
      tieneClave: conClaves(["gemini", "gemini-pro"])
    )
    #expect(plan.respaldo?.proveedor.id == "gemini")
  }

  @Test func sinClaveNoSeIntenta() {
    let modo = Modo(id: "correo", nombre: "Correo", prompt: "", proveedorID: "gemini")
    let plan = ResolucionDeProveedor.plan(
      para: modo, general: nil, catalogo: catalogo, tieneClave: conClaves([])
    )
    #expect(plan.noHayNadaQueIntentar)
  }

  @Test func elDeLocalhostEsLocalAunqueSeaCompatibleConOpenAI() {
    #expect(catalogo[3].esLocal)
    #expect(!catalogo[1].esLocal)
    #expect(catalogo[0].esLocal)
    #expect(!catalogo[3].necesitaClave)
  }
}
