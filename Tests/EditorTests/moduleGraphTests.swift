import App
import Canvas
import Chrome
import Editor
import Extensions
import Git
import Lang
import Lisp
import Org
import Platform
import Terminal
import Testing
import Text

/// Imports every Swift module in the package graph and asserts each `moduleName`
/// constant, so that a target which fails to build shows up as a named test failure
/// rather than a silent build break elsewhere in the suite.
@Suite("module graph")
struct ModuleGraphTests {
    @Test("every module reports its own name")
    func moduleNames() {
        #expect(PlatformModule.moduleName == "Platform")
        #expect(TextModule.moduleName == "Text")
        #expect(LispModule.moduleName == "Lisp")
        #expect(EditorModule.moduleName == "Editor")
        #expect(CanvasModule.moduleName == "Canvas")
        #expect(TerminalModule.moduleName == "Terminal")
        #expect(LangModule.moduleName == "Lang")
        #expect(OrgModule.moduleName == "Org")
        #expect(GitModule.moduleName == "Git")
        #expect(ExtensionsModule.moduleName == "Extensions")
        #expect(ChromeModule.moduleName == "Chrome")
        #expect(AppModule.moduleName == "App")
    }
}
