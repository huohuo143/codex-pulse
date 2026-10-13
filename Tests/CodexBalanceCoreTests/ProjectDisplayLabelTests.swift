import Testing
@testable import CodexBalanceCore

struct ProjectDisplayLabelTests {
  @Test func fileURLsDecodeOnceWhileIdentityAndLiteralPathsRemainIntact() {
    let raw = "file:///Volumes/work/%E7%A4%BA%E4%BE%8B%2520"
    let project = TokenProjectBucket(projectName: "%E7%A4%BA%E4%BE%8B%2520", projectPath: raw)
    #expect(ProjectDisplayLabel.name(project.projectName, path: raw) == "示例%20")
    #expect(ProjectDisplayLabel.path(raw) == "file:///Volumes/work/示例%20")
    #expect(project.id == raw)
    #expect(ProjectDisplayLabel.name("Trial%20Control", path: "file:///work/project") == "Trial%20Control")
    for path in ["/work/literal%20", "C:\\work\\literal%20"] {
      #expect(ProjectDisplayLabel.name("literal%20", path: path) == "literal%20")
      #expect(ProjectDisplayLabel.path(path) == path)
    }
  }

  @Test func invalidEncodingAndControlCharactersStayLiteral() {
    for value in ["file:///work/%ZZ", "file:///work/%0Aname", "file:///work/%FF"] {
      #expect(ProjectDisplayLabel.path(value) == value)
    }
  }
}
