//
//  TalkifyTests.swift
//  TalkifyTests
//
//  Created by Tornike Gomareli on 05/08/2026.
//

import Foundation
import Testing

/// La identidad del bundle que hospeda los tests. Se compara por prefijo y no
/// por igualdad porque toda copia legítima cuelga de ahí: `cl.espaciodigital.dilo`,
/// el `.mas` de App Store y el bundle id aparte con que se corre
/// `xcodebuild test` en este Mac para no pelear con la entrada de TCC de la app
/// instalada (AGENTS.md, "Cómo se compila y se prueba").
struct DiloTests {
  @Test func elHostEsDilo() {
    #expect(Bundle.main.bundleIdentifier?.hasPrefix("cl.espaciodigital.dilo") == true)
  }
}
