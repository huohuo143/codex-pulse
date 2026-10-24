import Foundation
import Testing
@testable import CodexMobileCore

@Suite("Mobile reset completion display")
struct MobileResetPresentationTests {
  let arrival=Date(timeIntervalSince1970:1792777277)
  private func radar() -> MobileRadar {
    .init(title:"重置已落地",summary:"本账号官方额度已恢复",sampledAt:arrival,checkedAt:arrival,
      validUntil:arrival.addingTimeInterval(660),deadline:nil,completionUntil:arrival.addingTimeInterval(86400),healthy:true,links:[])
  }
  @Test(arguments:[1.0,3600.0,86399.0,86400.0,86401.0])
  func appPanelAndWidgetShareOneFixedBoundary(age:Double) throws {
    let r=radar(), now=arrival.addingTimeInterval(age)
    let restored=try JSONDecoder().decode(MobileRadar.self,from:JSONEncoder().encode(r))
    #expect(restored.displayTitle(at:now) == (age<86400 ? "重置已落地" : "等待新重置"))
    #expect(restored.displayCompletionUntil(at:now) == (age<86400 ? arrival.addingTimeInterval(86400) : nil))
    #expect(!restored.hasAnnouncement(at:now))
    #expect(restored.displayDeadline(at:now) == nil)
  }
  @Test func sourceFailureDoesNotEraseArrivalAndRefreshCannotExtendIt() {
    var r=radar();r.healthy=false
    let now=arrival.addingTimeInterval(3600)
    #expect(!r.isCurrent(at:now))
    #expect(r.displayTitle(at:now) == "重置已落地")
    r.sampledAt=now;r.checkedAt=now;r.validUntil=now.addingTimeInterval(660)
    #expect(r.displayCompletionUntil(at:now) == arrival.addingTimeInterval(86400))
  }
  @Test func freshNewAnnouncementReplacesOldCompletion() {
    var r=radar();r.title="重置已预告";r.completionUntil=nil;r.deadline=arrival.addingTimeInterval(3600)
    #expect(r.hasAnnouncement(at:arrival))
    #expect(r.displayDeadline(at:arrival) == r.deadline)
    #expect(r.displayCompletionUntil(at:arrival) == nil)
  }
  @Test func futureCompletionCannotStartAnEarlyCountdown() {
    var r=radar();r.completionUntil=arrival.addingTimeInterval(86401)
    #expect(r.displayCompletionUntil(at:arrival) == nil)
    #expect(r.displayTitle(at:arrival) == "尚不能确认")
  }
  @Test func legacyLocalCompletionUsesSameRequestedLabel() {
    var r=radar();r.title="重置已落实"
    #expect(r.displayTitle(at:arrival) == "重置已落地")
  }
}
