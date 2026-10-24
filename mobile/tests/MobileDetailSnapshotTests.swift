import Foundation
import Testing
@testable import CodexMobileCore

@Suite("Expanded mobile snapshot boundaries")
struct MobileDetailSnapshotTests {
  let now=Date(timeIntervalSince1970:1_790_000_000)
  func base(_ account:String="a") -> MobileAccountSnapshot {
    MobileAccountSnapshot(publishedAt:now,device:.init(id:"mac",name:"Mac"),account:.init(id:account),quotaRead:.init(),windows:[])
  }
  func detail() -> MobileDetailSnapshot { MobileDetailSnapshot(publishedAt:now,device:.init(id:"mac",name:"Mac"),accountID:"a") }
  @Test func roundTripAndNoSyntheticMissingValues() throws {
    var d=detail();d.usage=MobileUsage();d.usage?.analysis=[MobileMetric("cache","缓存命中率")]
    let result=try MobileDetailSnapshot.decode(d.encoded(),now:now)
    #expect(result.usage?.analysis.first?.value == nil)
    #expect(result == d)
  }
  @Test func sourceAndAccountIsolationRejectsOldAccountDetails() {
    let d=detail()
    #expect(MobileDetailSnapshot.select([d],for:base("b"),previous:d) == nil)
    var other=d;other.device.id="other"
    #expect(MobileDetailSnapshot.select([other],for:base(),previous:nil) == nil)
    var newer=d;newer.publishedAt=now.addingTimeInterval(20)
    #expect(MobileDetailSnapshot.select([d],for:base(),previous:newer) == newer)
  }
  @Test func rejectsSensitiveProjectLabelsMalformedNumbersAndOversizedFiles() throws {
    var d=detail();d.usage=MobileUsage()
    d.usage?.projects=[MobileMetric(String(repeating:"a",count:64),"Secret project",5)]
    #expect(throws:MobileSnapshotError.self) { try d.validate(now:now) }
    d.usage?.projects=[MobileMetric(String(repeating:"a",count:64),"项目 · aaaaaaaa",5)]
    try d.validate(now:now)
    d.usage?.analysis=[MobileMetric("x","bad",.nan)]
    #expect(throws:MobileSnapshotError.self) { try d.validate(now:now) }
    #expect(throws:MobileSnapshotError.self) { try MobileDetailSnapshot.decode(Data(repeating:0,count:MobileDetailSnapshot.maximumBytes+1),now:now) }
  }
  @Test func rejectsInvalidHistoryAndInvalidCalendarDates() {
    var d=detail();d.history=[MobileHistoryPoint(date:now,remaining:101,resetAt:now.addingTimeInterval(10),segment:0)]
    #expect(throws:MobileSnapshotError.self) { try d.validate(now:now) }
    #expect(MobileCalendarDates.date("2026-02-30") == nil)
    #expect(MobileCalendarDates.date("2026-02-28") != nil)
    #expect(!MobileDetailSnapshot.safeURL("file:///private/path"))
    #expect(!MobileDetailSnapshot.safeURL("https://user:secret@example.com"))
  }
  @Test func staleRadarCannotClaimCurrentAndCSVQuotesFormulaCells() {
    let r=MobileRadar(title:"announced",summary:"",sampledAt:now,checkedAt:now,validUntil:nil,deadline:nil,completionUntil:nil,healthy:true,links:[])
    #expect(r.isCurrent(at:now))
    #expect(!r.isCurrent(at:now.addingTimeInterval(6000)))
    #expect(MobileExport.csvCell("=1+2") == "\"'=1+2\"")
    #expect(MobileExport.csvCell("a,\"b\"") == "\"a,\"\"b\"\"\"")
  }
}
