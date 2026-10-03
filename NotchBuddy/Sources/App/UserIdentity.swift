import Foundation

/// First name of the macOS account holder, or nil when the account name is not something
/// you would greet someone by. "Théodore Riant" gives "Théodore"; a login handle like
/// "theodoreriant" or "t.riant2" gives nil, because "Hey theodoreriant!" reads worse than
/// a greeting with no name at all.
func resolveUserFirstName() -> String? {
    let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !fullName.isEmpty, fullName.count <= maxUserFullNameLength else { return nil }
    guard !looksLikeLoginHandle(fullName) else { return nil }

    guard let first = fullName.split(separator: " ").first.map(String.init),
          !first.isEmpty,
          first.allSatisfy(isNamePart) else { return nil }
    return first
}

/// NSFullUserName() falls back to the short account name when the full name is unset, so a
/// single lowercase word, or one carrying digits or separators, is treated as a handle.
private func looksLikeLoginHandle(_ name: String) -> Bool {
    guard !name.contains(" ") else { return false }
    return name == name.lowercased() || name.contains(where: isHandleMarker)
}

private func isHandleMarker(_ character: Character) -> Bool {
    character.isNumber || "._-@".contains(character)
}

private func isNamePart(_ character: Character) -> Bool {
    character.isLetter || character == "'" || character == "-"
}

private let maxUserFullNameLength = 32
