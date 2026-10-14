import Darwin

/// Lo que cuesta un trozo de código en CPU del hilo que lo corre, y no en
/// reloj de pared.
///
/// Un test de costo con reloj de pared mide también cuánto esperó la CPU, y
/// con la máquina ocupada —otra compilación, la suite corriendo en paralelo—
/// falla sin que el código haya empeorado. El tiempo de CPU del hilo no
/// cuenta esa espera. Se queda con la mejor de varias pasadas para que un
/// fallo de caché o una interrupción tampoco cuenten.
enum CostoDeCPU {
  static func medir(pasadas: Int = 3, _ cuerpo: () throws -> Void) rethrows -> Duration {
    var mejor = Duration.seconds(Int64.max)
    for _ in 0..<max(pasadas, 1) {
      let antes = ahora()
      try cuerpo()
      mejor = min(mejor, ahora() - antes)
    }
    return mejor
  }

  private static func ahora() -> Duration {
    var t = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
    return .seconds(t.tv_sec) + .nanoseconds(t.tv_nsec)
  }
}
