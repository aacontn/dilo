import Foundation

/// Una voz de Phonon en español, del catálogo `gradium/phonon-voices`
/// (Apache 2.0).
public struct VozDePhonon: Sendable, Equatable, Identifiable {
  public enum Acento: String, Sendable { case espana, mexico }
  public enum Genero: Sendable { case mujer, hombre }

  /// El nombre visible, y lo que se guarda en Ajustes. El archivo se pide por
  /// `archivo`: un nombre con tilde no siempre viaja con la misma
  /// normalización Unicode, y el CLI no encontraba a «Lucía-Sol».
  public let nombre: String
  public let archivo: String
  public let acento: Acento
  public let genero: Genero
  /// SHA-256 del `.safetensors` publicado en la revisión fija del catálogo.
  public let sha256: String

  public var id: String { nombre }
}

/// Las 25 voces en español —13 de España, 12 de México— y la de fábrica.
///
/// No hay voces chilenas en el catálogo. Pesan 250 KB cada una y se bajan
/// sólo cuando se eligen.
public enum VocesDePhonon {
  /// La revisión del catálogo con la que se verificaron los hashes.
  public static let revision = "da6c9ec0d47be8df5c87c730a3aa97187f3229c3"

  /// La de fábrica la decidió el banco de voces (`scripts/taller-voces.sh`,
  /// 2026-10-29): entre las de México, que es el acento más cercano al de
  /// Chile de los dos que hay, la de menos errores al transcribirla de vuelta
  /// con Parakeet en dos pasadas de seis frases chilenas (5,2 % de WER en
  /// promedio, empatada con Jimena). Entre voces la diferencia es de ±2
  /// puntos, que es lo que varía una misma voz de una pasada a otra: el
  /// número elige, pero el oído de Alfonso manda.
  public static let deFabrica = "Danae"

  public static let todas: [VozDePhonon] = [
    .init(nombre: "Noa", archivo: "b6FvJAiokjdqIti4", acento: .espana, genero: .mujer, sha256: "0bc37938a306a35f6c9f8ea53ccca14c5fc8b5575850f0cd15b352f4c3ce826e"),
    .init(nombre: "Lucía-Sol", archivo: "3p0eIGbkmny71GlA", acento: .espana, genero: .mujer, sha256: "275928c11b3c8b02e51c72653d060433e1d73a01458ef21b18e9a7f5cbd5205c"),
    .init(nombre: "Candela", archivo: "c9wqBDmQiBie5q6Y", acento: .espana, genero: .mujer, sha256: "4857d013c7502e4d074778b17122e85919bffa52741a0072e412dd3926853dcb"),
    .init(nombre: "Celia", archivo: "rmLBOdHrfkFym9MM", acento: .espana, genero: .mujer, sha256: "6ed37f47fe59674b0c9f2c099ab983d4a847ca14d09aedf80f1608a11148c757"),
    .init(nombre: "Alba", archivo: "u2UscyAnHilpiwmf", acento: .espana, genero: .mujer, sha256: "edd14cc89944ec7a9b1a87cc6be6f371f1a56791d344d921f850e2106e6dee9e"),
    .init(nombre: "Alicia", archivo: "4701YgRXjkBcg6sL", acento: .espana, genero: .mujer, sha256: "74c6bf732b76478e77072d21feca13b0bf0c664eccd2186902a63ba0d9effe59"),
    .init(nombre: "Nerea", archivo: "EQcQFGkYfMn5YJgx", acento: .espana, genero: .mujer, sha256: "c419a49606182c98e06c369d0cfb9b66cc0f16bfdbc70490fa7daf2289144986"),
    .init(nombre: "Marcos", archivo: "jvPx8j8zLGQ3utZz", acento: .espana, genero: .hombre, sha256: "be8c5f329070f40c39007bea13cee9503fe71599704cfe55c67d6eb51f5e6eb2"),
    .init(nombre: "Borja", archivo: "tIjCgP8v3RY8UpgM", acento: .espana, genero: .hombre, sha256: "fc8828dcdad4a09b7066b9008b108b77976ec4880d531da7761ded9a431bd208"),
    .init(nombre: "Iker", archivo: "t-_TS1e-0GzDAX02", acento: .espana, genero: .hombre, sha256: "25c6df91a261bcb96d9e5152c9b0988398859c0e6f4ee5f08dd577fd3bd0300d"),
    .init(nombre: "Nuno", archivo: "fghJGlv90qu8OJ36", acento: .espana, genero: .hombre, sha256: "60656e9cd518454850a7e6ecacb953572a4a23f0a358fe3b4fb946b67f6bf934"),
    .init(nombre: "Izan", archivo: "Ejb29qHnSOK0cIHY", acento: .espana, genero: .hombre, sha256: "471332253b2f76c406e395230453a7a737708cca18461237cfce0239430cb071"),
    .init(nombre: "Guillermo", archivo: "FaLVVqpFQcDOtq45", acento: .espana, genero: .hombre, sha256: "31a3837cc6705f37f95c27282ebeba71609b32204622245a6436258cd3d3497d"),
    .init(nombre: "Rebeca", archivo: "Sx8m6WdXBG06zwZT", acento: .mexico, genero: .mujer, sha256: "8756dddf95fa449d0e5a8649c6a242a460329c53e2f870bbe6ed744d0573a251"),
    .init(nombre: "Regina", archivo: "s58clrg2fe0MO7Y-", acento: .mexico, genero: .mujer, sha256: "ab923d4fd9ed09954e3a91c61780bcd536f5bb5787e1d0541cb6ff56dd7ff531"),
    .init(nombre: "Danae", archivo: "evfxKSxpDIhmsNoq", acento: .mexico, genero: .mujer, sha256: "549f2a8dec851b967edbbd67b29d2da0799eec9ec2fefb5b0ec8aa99436d3eea"),
    .init(nombre: "Azucena", archivo: "KJpIQlbYrZPA4aLq", acento: .mexico, genero: .mujer, sha256: "b5bcbbce39a6332b2f79067be19688753c28c1fc4053bf41fd4608d54c24e1ee"),
    .init(nombre: "Jimena", archivo: "qG5BXOJYrKEnXLIX", acento: .mexico, genero: .mujer, sha256: "3d5590357dbd87b697a14573bbdc1f29e2abc5b6cd8a5e9ed3c98e325dede435"),
    .init(nombre: "Ximena", archivo: "VDwnGxAo68C8U8vC", acento: .mexico, genero: .mujer, sha256: "ccb1b88e3899db1cb7ba71007d08ed56dd743882214f0495b67feab89850ffe0"),
    .init(nombre: "Lalo", archivo: "F05gqkzX7WhKVpSL", acento: .mexico, genero: .hombre, sha256: "08159aad0d92cb391361abaf8c4bf6ac0d8358ab1514cce8cf5c89b448395ce5"),
    .init(nombre: "Aldo", archivo: "ax7dW1XB0eiMfHgO", acento: .mexico, genero: .hombre, sha256: "128eeba9b5f5c6d336e1246ae20a40765fba8e5ac268aafa691b98bce1e0acfd"),
    .init(nombre: "Yael", archivo: "ALczEazoF4n6PmGl", acento: .mexico, genero: .hombre, sha256: "f4ebe6b59ebfa09339cb4c15c9c8f0af72fb6cecd9feb1f550dee0d95c8092c1"),
    .init(nombre: "Ulises", archivo: "G5HLUsQd659UtRe7", acento: .mexico, genero: .hombre, sha256: "fba1a4349c3c86aabc58d6570a82fac0ed643e5e7aa97b52a3ede6b792e6d420"),
    .init(nombre: "Leonel", archivo: "BkuASiOJRrJEB5qA", acento: .mexico, genero: .hombre, sha256: "d32ad93e71b8c726a8f1aac62f276db82346fc1a74a02cfc18ce2b867cf20a07"),
    .init(nombre: "Nico", archivo: "PwgPEaweQILZdGc4", acento: .mexico, genero: .hombre, sha256: "91af1c0e9233b3069fab26eabd191e6be4d7825eff5d5e1ce3034fbd8f7fcf24"),
  ]

  /// La voz guardada en Ajustes, o la de fábrica si está vacía o ya no existe.
  public static func voz(_ nombre: String) -> VozDePhonon {
    todas.first { $0.nombre == nombre } ?? todas.first { $0.nombre == deFabrica }!
  }

  public static func url(de voz: VozDePhonon) -> URL {
    URL(string: "https://huggingface.co/gradium/phonon-voices/resolve/\(revision)/voices/\(voz.archivo).safetensors")!
  }
}
