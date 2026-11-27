import CoreGraphics
import DabaiPetCore
import Testing

struct ChatPanelGeometryTests {
    @Test func allCornersOnTwoScreens() {
        for area in [CGRect(x: 0, y: 38, width: 1200, height: 800),
                     CGRect(x: -1420, y: -320, width: 1280, height: 720)] {
            for x in [area.minX, area.maxX-142] {
                for y in [area.minY, area.maxY-174] {
                    let pet = CGRect(x: x,y: y,width: 142,height: 174)
                    let chat = ScreenGeometry.chatPanelFrame(petFrame: pet, visibleFrame: area)
                    #expect(chat.size == CGSize(width: 290, height: 270))
                    #expect(area.contains(chat))
                    #expect(y == area.minY ? chat.minY > pet.maxY : chat.maxY < pet.minY)
                }
            }
        }
    }

    @Test func preferredAboveThenSideWhenVerticalSpaceIsShort() {
        let pet = CGRect(x: 380, y: 320, width: 142, height: 174)
        let chat = ScreenGeometry.chatPanelFrame(petFrame: pet, visibleFrame: CGRect(x: 0,y: 0,width: 900,height: 900))
        #expect(chat.midX == pet.midX && chat.minY > pet.maxY)
        let short = CGRect(x: -100,y: 0,width: 1000,height: 350)
        for x in [short.minX, short.maxX-142] {
            let pet = CGRect(x: x,y: 90,width: 142,height: 174)
            let chat = ScreenGeometry.chatPanelFrame(petFrame: pet, visibleFrame: short)
            #expect(short.contains(chat))
            #expect(x == short.minX ? chat.minX > pet.maxX : chat.maxX < pet.minX)
        }
    }

    @Test func smallVisibleAreaFitsClampedSize() {
        let visible = CGRect(x: -90, y: -30, width: 180, height: 160)
        #expect(ScreenGeometry.chatPanelFrame(petFrame: visible.insetBy(dx: 10, dy: 10), visibleFrame: visible) == visible)
    }
}
