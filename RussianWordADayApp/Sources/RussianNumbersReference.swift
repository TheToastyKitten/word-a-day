import Foundation

/// Russian numerals 0…20 bundled in `dictionary.sqlite` (stable `words.id` values).
enum RussianNumbersReference {
    static let rows: [(value: Int, wordID: String)] = [
        (0, "nol"),
        (1, "odin"),
        (2, "dva"),
        (3, "tri"),
        (4, "chetyre"),
        (5, "pyat"),
        (6, "shest"),
        (7, "sem"),
        (8, "vosem"),
        (9, "devyat"),
        (10, "desyat"),
        (11, "odinnadtsat"),
        (12, "dvenadtsat"),
        (13, "trinadtsat"),
        (14, "chetyrnadtsat"),
        (15, "pyatnadtsat"),
        (16, "shestnadtsat"),
        (17, "semnadtsat"),
        (18, "vosemnadtsat"),
        (19, "devyatnadtsat"),
        (20, "dvadtsat"),
    ]
}
