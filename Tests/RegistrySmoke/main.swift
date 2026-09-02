import Foundation

let records = SessionCatalog.shared.listLiveSessions()
guard let record = records.first else {
    fputs("automatic-sync registry smoke failed: no live session\n", stderr)
    exit(1)
}
guard !record.sessionId.isEmpty,
      !record.cwd.isEmpty,
      !record.link.isEmpty,
      record.summary.id == record.sessionId,
      record.liveSummary.id == record.sessionId else {
    fputs("automatic-sync registry smoke failed: malformed live session\n", stderr)
    exit(1)
}
print("automatic-sync registry discovery passed")
