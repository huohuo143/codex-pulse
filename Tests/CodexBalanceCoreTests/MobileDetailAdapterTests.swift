import Foundation
import Testing
import CodexMobileCore
@testable import CodexBalanceCore

@Suite("Anonymous mobile detail adapter")
struct MobileDetailAdapterTests {
  let now=Date(timeIntervalSince1970:1_790_000_000)
  @Test func projectAndBudgetUseSameAnonymousIdentityWithoutPrivateFields() throws {
    var status=MobileSnapshotPublisherTests().status()
    status.tokenStats=TokenStats(todayTokens:12,monthTokens:34,last7DaysTokens:20,
      monthTopProjects:[.init(projectName:"Confidential rice study",projectPath:"/private/research/study",totalTokens:34,calls:2)])
    status.tokenStats.cost24Hours = CostEstimate(unpricedTokens:12)
    let budget=ProjectBudget(projectName:"Confidential rice study",projectPath:"/private/research/study",monthlyTokenLimit:100)
    func make(_ device:String="mac") -> MobileDetailSnapshot {
      MobileDetailAdapter.make(status:status,device:.init(id:device,name:"Mac"),usageAt:now,history:[],forecast:nil,budgets:[budget],radar:nil,rate:nil,health:.init(generatedAt:now))
    }
    let d=make();let encoded=String(decoding:try d.encoded(),as:UTF8.self)
    for secret in ["Confidential rice study","/private","anonymous-local-scope","projectPath","sourcePath","codexHome"] { #expect(!encoded.contains(secret)) }
    #expect(d.usage?.projects.first?.id == d.usage?.budgets.first?.id)
    #expect(d.usage?.projects.first?.id == make().usage?.projects.first?.id)
    #expect(d.usage?.projects.first?.id != make("other").usage?.projects.first?.id)
    #expect(d.usage?.today == 12)
    #expect(d.usage?.costs.first?.value == nil)
    #expect(d.usageSampledAt == now)
  }
  @Test func noSamplingMeansNoInventedZeroStatisticsAndNoAccountHistory() throws {
    let d=MobileDetailAdapter.make(status:MobileSnapshotPublisherTests().status(scope:nil),device:.init(id:"mac",name:"Mac"),usageAt:nil,history:[],forecast:nil,budgets:[],radar:nil,rate:nil,health:.init(generatedAt:now))
    #expect(d.usage == nil);#expect(d.accountID == nil);#expect(d.credits.isEmpty);#expect(d.history.isEmpty)
    try d.validate()
  }
  @Test func detailPublisherKeepsBaseCompatibleAndRejectsOutOfOrderAccountWrites() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let publisher=MobileSnapshotPublisher(root:root,deviceID:"mac",deviceName:"Mac")
    let first=MobileSnapshotPublisherTests().status()
    _ = try await publisher.publish(first)
    try await publisher.publishDetails(status:first,usageAt:now,history:[],forecast:nil,budgets:[],radar:nil,rate:nil,health:.init(generatedAt:now))
    let next=MobileSnapshotPublisherTests().status(scope:"new",date:now.addingTimeInterval(120))
    try await publisher.publishDetails(status:next,usageAt:now,history:[],forecast:nil,budgets:[],radar:nil,rate:nil,health:.init(generatedAt:now))
    try await publisher.publishDetails(status:first,usageAt:now,history:[],forecast:nil,budgets:[],radar:nil,rate:nil,health:.init(generatedAt:now))
    let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
    let detail=try MobileDetailSnapshot.decode(Data(contentsOf:#require(files.first {$0.lastPathComponent.hasPrefix("detail-")})))
    let base=try MobileAccountSnapshot.decode(Data(contentsOf:#require(files.first {$0.lastPathComponent.hasPrefix("device-")})))
    #expect(base.publishedAt == now)
    #expect(detail.publishedAt == now.addingTimeInterval(120))
    #expect(!detail.matches(base))
  }

  @Test func resetStateChangesBypassOneMinuteDetailHeartbeat() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let publisher=MobileSnapshotPublisher(root:root,deviceID:"mac",deviceName:"Mac")
    let start=Date()
    var radar=try JSONDecoder().decode(CodexRadarSnapshot.self,from:Data("{}".utf8))
    radar.syncState = .init(lastAttemptAt:start,lastSuccessAt:start)
    radar.tiboAnalysis = .init(state:.announced,kind:.hard_reset,summaryZh:"已预告",timingZh:"",evidenceIDs:[],analyzedAt:start)
    func publish(_ r:CodexRadarSnapshot, at date:Date) async throws {
      let value=MobileSnapshotPublisherTests().status(date:date)
      try await publisher.publishDetails(status:value,usageAt:nil,history:[],forecast:nil,budgets:[],radar:r,rate:nil,health:.init(generatedAt:date))
    }
    func loaded() throws -> MobileDetailSnapshot {
      let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
      return try MobileDetailSnapshot.decode(Data(contentsOf:#require(files.first {$0.lastPathComponent.hasPrefix("detail-")})))
    }
    try await publish(radar,at:start)
    radar.quotaResetConfirmedAt=start.addingTimeInterval(-120)
    try await publish(radar,at:start.addingTimeInterval(5))
    #expect(try loaded().radar?.title == "重置已落地")
    #expect(try loaded().radar?.completionUntil == start.addingTimeInterval(86280).roundedToSecond)
    let arrivalPublishedAt=try loaded().publishedAt
    try await publish(radar,at:start.addingTimeInterval(10))
    #expect(try loaded().publishedAt == arrivalPublishedAt)
    radar.tiboLatestAnnouncementAt=start.addingTimeInterval(11)
    radar.syncState = .init(lastAttemptAt:start.addingTimeInterval(12),lastSuccessAt:start.addingTimeInterval(12))
    radar.tiboAnalysis?.analyzedAt=start.addingTimeInterval(12)
    try await publish(radar,at:start.addingTimeInterval(12))
    #expect(try loaded().radar?.completionUntil == nil)
    #expect(try loaded().radar?.title == "重置已预告")
  }

}

private extension Date {
  var roundedToSecond: Date { Date(timeIntervalSince1970:timeIntervalSince1970.rounded(.down)) }
}
