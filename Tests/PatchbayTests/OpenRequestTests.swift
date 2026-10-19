import Foundation
import Testing
@testable import Patchbay

/// `patchbay/open` requests from other apps.
struct OpenRequestTests {
    let folder = NSTemporaryDirectory()

    func error(_ params: [String: Any]) -> String? {
        do {
            _ = try OpenRequest(params)
            return nil
        } catch {
            return (error as? ToolError)?.message
        }
    }

    @Test func resumeOrPrompt() throws {
        let resume = try OpenRequest(["folder": folder, "resume": "abc", "name": "D5402 review"])
        #expect(resume.resume == "abc")
        #expect(resume.prompt == nil)
        #expect(resume.name == "D5402 review")
        #expect(try OpenRequest(["folder": folder, "prompt": "/review 5402"]).prompt == "/review 5402")
        #expect(try OpenRequest(["folder": folder]).resume == nil)
    }

    @Test func folderIsRequired() {
        #expect(error([:]) == "folder is required")
    }

    @Test func notBothResumeAndPrompt() {
        #expect(error(["folder": folder, "resume": "abc", "prompt": "hi"]) == "Pass resume or prompt, not both")
    }

    @Test func folderMustExist() {
        #expect(error(["folder": "/no/such/folder"]) == "No folder at /no/such/folder")
    }
}
