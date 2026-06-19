import Testing
@testable import Yana

@MainActor
struct ToastMessageTests {
    @Test func defaultStyleIsInfo() {
        let msg = ToastMessage(text: "Hello")
        #expect(msg.style == .info)
        #expect(msg.text == "Hello")
    }

    @Test func errorStyleIsPreserved() {
        let msg = ToastMessage(text: "Boom", style: .error)
        #expect(msg.style == .error)
    }

    @Test func equatableComparesTextAndStyle() {
        #expect(ToastMessage(text: "a") == ToastMessage(text: "a"))
        #expect(ToastMessage(text: "a") != ToastMessage(text: "a", style: .error))
        #expect(ToastMessage(text: "a") != ToastMessage(text: "b"))
    }
}
