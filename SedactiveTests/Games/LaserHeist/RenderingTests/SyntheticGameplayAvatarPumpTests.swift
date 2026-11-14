import Foundation
import Testing
@testable import Sedactive

@MainActor struct SyntheticGameplayAvatarPumpTests {
  @Test func packetDeliveryIsBoundedAndRetryUsesNewContext() throws {
    var time = 100.0
    let box = AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge)
    let pump = try SyntheticGameplayAvatarPump(mailbox:box,now:{time})
    time += 0.1
    #expect(try pump.tick())
    #expect(box.diagnostics.accepted == 1)
    #expect(try pump.tick())
    #expect(box.diagnostics.accepted == 1)
    pump.stop()
    #expect(box.isRevoked)
    #expect(try pump.tick() == false)
    let fresh = AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge)
    let retry = try SyntheticGameplayAvatarPump(mailbox:fresh,now:{time})
    time += 0.1; #expect(try retry.tick())
    #expect(fresh.diagnostics.accepted == 1 && box.isRevoked)
    retry.stop()
  }
}
