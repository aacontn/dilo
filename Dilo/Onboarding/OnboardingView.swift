import DiloCapabilities
import DiloEngines
import SwiftUI

/// Los primeros pasos de Dilo: saluda, pide los permisos explicando cada uno,
/// deja elegir motor y hace dictar una vez, ahí mismo.
///
/// Es la misma superficie que Ajustes —mismo encabezado, mismo cromo, mismas
/// tarjetas— a propósito: lo que la persona ve la primera vez tiene que ser lo
/// que va a volver a ver cuando abra Ajustes, o el onboarding le enseña una
/// app que no existe.
struct OnboardingView: View {
  @Bindable var settings: AppSettings
  let permisos: EstadoDePermisos
  let onClose: () -> Void

  @State private var paso: Paso = .bienvenida
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  enum Paso: Int, CaseIterable {
    case bienvenida
    case permisos
    case motor
    case prueba
  }

  var body: some View {
    VStack(spacing: 0) {
      SettingsHeader(onClose: onClose)

      ZStack {
        contenido
          .id(paso)
          .transition(.opacity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: paso)

      BarraDePasos(
        paso: paso,
        atras: paso == .bienvenida ? nil : { mover(-1) },
        seguir: paso == .prueba ? nil : { mover(1) },
        terminar: paso == .prueba ? onClose : nil
      )
    }
    .frame(width: 720, height: 560)
    .superficieDeDilo()
    .onExitCommand(perform: onClose)
    // El motor se puede cambiar en el paso tres, y de eso depende si hace
    // falta el permiso de Reconocimiento de voz.
    .onChange(of: settings.motorDeVoz) { _, motor in
      permisos.motorEsApple = motor == .apple
    }
  }

  @ViewBuilder
  private var contenido: some View {
    switch paso {
    case .bienvenida:
      PasoDeBienvenida(gatillo: settings.dictationTriggerBinding.label)
    case .permisos:
      PasoDePermisos(permisos: permisos)
    case .motor:
      PasoDeMotor(settings: settings, permisos: permisos)
    case .prueba:
      PasoDePrueba(gatillo: settings.dictationTriggerBinding.label)
    }
  }

  private func mover(_ pasos: Int) {
    let siguiente = Paso(rawValue: paso.rawValue + pasos) ?? paso
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
      paso = siguiente
    }
  }
}

/// El marco de cada paso: título grande, bajada y contenido, con la misma
/// tipografía y los mismos márgenes que una sección de Ajustes.
private struct Lamina<Contenido: View>: View {
  let titulo: String
  let bajada: String
  @ViewBuilder let contenido: Contenido

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 6) {
          Text(titulo)
            .font(.system(size: 26, weight: .semibold, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
          Text(bajada)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(contrast == .increased ? 0.76 : 0.52))
            .fixedSize(horizontal: false, vertical: true)
        }

        contenido
      }
      .frame(maxWidth: 600, alignment: .leading)
      .padding(.horizontal, 34)
      .padding(.vertical, 28)
    }
  }
}

private struct PasoDeBienvenida: View {
  let gatillo: String

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    VStack(spacing: 22) {
      Spacer(minLength: 0)

      Image("MenuBarIcon")
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: 34, height: 34)
        .foregroundStyle(SettingsTheme.accent)
        .frame(width: 68, height: 68)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

      Text("Aprieta, habla, suelta. Ya está escrito.")
        .font(.system(size: 30, weight: .semibold, design: .rounded))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 12) {
        HStack(spacing: 8) {
          Text("Tu tecla es")
            .foregroundStyle(.white.opacity(contrast == .increased ? 0.82 : 0.6))
          Tecla(gatillo)
        }
        .font(.system(size: 14))

        Text(
          "Manténla apretada mientras hablas y suéltala cuando termines. El texto aparece donde está tu cursor, en la app en la que estabas escribiendo. Todo pasa en este Mac."
        )
        .font(.system(size: 13))
        .multilineTextAlignment(.center)
        .foregroundStyle(.white.opacity(contrast == .increased ? 0.72 : 0.5))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 420)
      }

      Text("Son tres pantallas y un dictado de prueba. Un minuto.")
        .font(.caption)
        .foregroundStyle(.white.opacity(0.4))

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// La tecla del gatillo dibujada como tecla. El mismo dato que muestra el menú
/// de la barra (`KeyBinding.label`), así que nunca puede decir una tecla que
/// no sea la configurada.
private struct Tecla: View {
  let texto: String

  init(_ texto: String) { self.texto = texto }

  var body: some View {
    Text(texto)
      .font(.system(size: 13, weight: .semibold, design: .rounded))
      .foregroundStyle(.white)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(.white.opacity(0.16), lineWidth: 1)
      }
  }
}

private struct PasoDePermisos: View {
  let permisos: EstadoDePermisos

  var body: some View {
    Lamina(
      titulo: "Los permisos, uno por uno",
      bajada: "Ninguno es raro, y cada uno dice para qué lo quiere Dilo. Los das en Ajustes del Sistema y esta pantalla se entera sola."
    ) {
      VStack(spacing: 16) {
        SettingsCard(title: "Lo que Dilo necesita") {
          ForEach(permisos.pasos, id: \.self) { permiso in
            FilaDePermiso(
              permiso: permiso,
              estado: permisos.estado(de: permiso),
              pedir: { permisos.pedir(permiso) },
              abrirAjustes: { permisos.abrirAjustes(de: permiso) }
            )
          }
        }

        if permisos.todosConcedidos {
          AvisoDeDilo(
            icono: "checkmark.circle.fill",
            color: DiloBrand.menta,
            texto: "Todo listo. Sigue y elige con qué motor quieres dictar."
          )
        } else {
          AvisoDeDilo(
            icono: "info.circle.fill",
            color: SettingsTheme.accent,
            texto: "Accesibilidad y Monitoreo de entrada se marcan a mano en Ajustes del Sistema. Si acabas de marcar uno y Dilo sigue sin oír la tecla, ciérralo y ábrelo de nuevo: macOS aplica esos dos al arrancar."
          )
        }
      }
      // TCC cambia por fuera del proceso: la persona sale a marcar la casilla
      // y vuelve, y la fila tiene que haberse actualizado sin que apriete nada.
      .task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1))
          permisos.refrescar()
        }
      }
    }
  }
}

private struct FilaDePermiso: View {
  let permiso: Permiso
  let estado: EstadoDePermisos.Estado
  let pedir: () -> Void
  let abrirAjustes: () -> Void

  var body: some View {
    SettingsRow(title: "\(permiso.titulo)", description: "\(permiso.porque)") {
      HStack(spacing: 10) {
        if estado == .concedido {
          Label("Listo", systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DiloBrand.menta)
          Button("Ajustes", action: abrirAjustes)
            .buttonStyle(SettingsButtonStyle())
        } else {
          Text("Falta")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(SettingsTheme.accent)
          Button("Dar permiso", action: pedir)
            .buttonStyle(SettingsButtonStyle())
        }
      }
    }
  }
}

private struct PasoDeMotor: View {
  @Bindable var settings: AppSettings
  let permisos: EstadoDePermisos

  var body: some View {
    Lamina(
      titulo: "Quién convierte tu voz en texto",
      bajada: "Los dos transcriben dentro de este Mac: tu audio no sale de acá. Puedes cambiarlo cuando quieras en Ajustes → Motor."
    ) {
      VStack(spacing: 16) {
        // La misma pantalla que Ajustes → Motor, no una copia con otro copy.
        SelectorDeMotor(settings: settings)

        // Elegir Apple acá estrena un permiso que el paso anterior no pidió,
        // porque con Parakeet no hacía falta. Se pide en el momento en que
        // empieza a hacer falta, no una pantalla después.
        if settings.motorDeVoz == .apple,
          permisos.estado(de: .reconocimientoDeVoz) == .falta {
          SettingsCard(title: "Falta un permiso") {
            FilaDePermiso(
              permiso: .reconocimientoDeVoz,
              estado: .falta,
              pedir: { permisos.pedir(.reconocimientoDeVoz) },
              abrirAjustes: { permisos.abrirAjustes(de: .reconocimientoDeVoz) }
            )
          }
        }
      }
    }
  }
}

/// El dictado de prueba, en esta misma ventana.
///
/// No hay nada especial detrás: el gatillo es global y el texto se pega donde
/// está el cursor, y acá el cursor está en este campo. Probarlo así es probar
/// el camino de verdad, no una simulación de él.
private struct PasoDePrueba: View {
  let gatillo: String

  @State private var texto = ""
  @FocusState private var enfocado: Bool
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Lamina(
      titulo: "Pruébalo de verdad",
      bajada: "Deja el cursor en el recuadro, mantén la tecla, di algo y suelta. La píldora aparece arriba mientras hablas."
    ) {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 8) {
          Text("Mantén")
            .foregroundStyle(.white.opacity(contrast == .increased ? 0.82 : 0.58))
          Tecla(gatillo)
          Text("y di «hola, esto es una prueba»")
            .foregroundStyle(.white.opacity(contrast == .increased ? 0.82 : 0.58))
        }
        .font(.system(size: 13))

        ZStack(alignment: .topLeading) {
          TextEditor(text: $texto)
            .focused($enfocado)
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(height: 160)
            .background(
              SettingsTheme.card,
              in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                  texto.isEmpty
                    ? .white.opacity(contrast == .increased ? 0.22 : 0.09)
                    : DiloBrand.menta.opacity(0.45),
                  lineWidth: 1
                )
            }
            .accessibilityLabel("Campo para probar el dictado")

          if texto.isEmpty {
            Text("Tu dictado aparecerá acá…")
              .font(.system(size: 14))
              .foregroundStyle(.white.opacity(0.28))
              .padding(.horizontal, 15)
              .padding(.vertical, 18)
              .allowsHitTesting(false)
          }
        }

        if texto.isEmpty {
          Text(
            "Si no aparece nada: revisa que Micrófono, Accesibilidad y Monitoreo de entrada estén dados en el paso anterior. Los dos últimos macOS se los aplica a Dilo al arrancar, así que puede hacer falta cerrarlo y abrirlo."
          )
          .font(.caption)
          .foregroundStyle(.white.opacity(0.42))
          .fixedSize(horizontal: false, vertical: true)
        } else {
          AvisoDeDilo(
            icono: "checkmark.circle.fill",
            color: DiloBrand.menta,
            texto: "Listo, Dilo funciona. Eso que dijiste lo transcribió y lo pegó él."
          )
        }
      }
      .onAppear { enfocado = true }
    }
  }
}


/// El pie: en qué paso vas y cómo pasar al siguiente.
private struct BarraDePasos: View {
  let paso: OnboardingView.Paso
  let atras: (() -> Void)?
  let seguir: (() -> Void)?
  let terminar: (() -> Void)?

  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    HStack(spacing: 12) {
      if let atras {
        Button("Atrás", action: atras)
          .buttonStyle(SettingsButtonStyle())
      }

      Spacer()

      HStack(spacing: 6) {
        ForEach(OnboardingView.Paso.allCases, id: \.rawValue) { candidato in
          Circle()
            .fill(
              candidato == paso
                ? SettingsTheme.accent
                : .white.opacity(contrast == .increased ? 0.3 : 0.16)
            )
            .frame(width: 6, height: 6)
        }
      }
      .accessibilityLabel("Paso \(paso.rawValue + 1) de \(OnboardingView.Paso.allCases.count)")

      Spacer()

      if let seguir {
        Button("Seguir", action: seguir)
          .buttonStyle(SettingsButtonStyle())
      }
      if let terminar {
        Button("Empezar a usar Dilo", action: terminar)
          .buttonStyle(SettingsButtonStyle())
      }
    }
    .padding(.horizontal, 20)
    .frame(height: 60)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(.white.opacity(contrast == .increased ? 0.18 : 0.08))
        .frame(height: 1)
    }
  }
}

#Preview {
  OnboardingView(
    settings: AppSettings.previewStore(),
    permisos: EstadoDePermisos(motorEsApple: false),
    onClose: {}
  )
}
