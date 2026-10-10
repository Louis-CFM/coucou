// Minimal stubs for IslandMode and IslandView — used only by standalone test compilation.
// The real definitions live in Sources/CoucouKit/IslandTypes.swift.
import Foundation

enum IslandMode: String, CaseIterable {
    case hidden, compact, expanded
}

enum IslandView: String, CaseIterable {
    case overview, empty, approval, question, error, finished
    case confused, upload, uploading, choose, mail, prompt
    case searching, result, note, settings, greeting, wardrobe, recap
    case listening
    case voiceResult
}
