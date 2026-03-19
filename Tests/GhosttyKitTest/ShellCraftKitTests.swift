import GhosttyTerminal
@testable import ShellCraftKit
import Testing

struct ShellCraftKitTests {
    @Test
    func styledPromptUsesVisibleColumnWidth() {
        let shell = ShellDefinition(
            prompt: "\u{1B}[38;5;110mcolor\u{1B}[0m > ",
            welcomeMessage: ""
        ) {}

        #expect(shell.promptDisplayWidth == 8)
    }

    @Test
    func terminalDisplayWidthCountsWideCharacters() {
        #expect("abc".terminalDisplayWidth == 3)
        #expect("你好".terminalDisplayWidth == 4)
        #expect("a你b好".terminalDisplayWidth == 6)
        #expect("\u{1B}[31m红色\u{1B}[0m".terminalDisplayWidth == 4)
    }

    @Test
    func cursorColumnUsesDisplayWidthInsteadOfCharacterCount() {
        #expect(
            terminalCursorColumn(
                promptDisplayWidth: 8,
                input: "测试",
                cursorPosition: 2
            ) == 13
        )

        #expect(
            terminalCursorColumn(
                promptDisplayWidth: 8,
                input: "a测b",
                cursorPosition: 2
            ) == 12
        )

        #expect(
            terminalCursorColumn(
                promptDisplayWidth: 8,
                input: "你好吗",
                cursorPosition: 1
            ) == 11
        )
    }

    @Test
    func renderedInputStateTracksWrappedLinesAndCursorPlacement() {
        let state = terminalRenderedInputState(
            promptDisplayWidth: 18,
            input: "hello world",
            cursorPosition: 11,
            terminalColumns: 20
        )

        #expect(state.totalLineCount == 2)
        #expect(state.cursorLineOffset == 1)
        #expect(state.cursorColumn == 10)
    }

    @Test
    func renderedInputStateHandlesPromptOnlyWrapping() {
        let state = terminalRenderedInputState(
            promptDisplayWidth: 18,
            input: "",
            cursorPosition: 0,
            terminalColumns: 10
        )

        #expect(state.totalLineCount == 2)
        #expect(state.cursorLineOffset == 1)
        #expect(state.cursorColumn == 9)
    }

    @Test
    func wrappedTerminalLineCountHandlesExactBoundary() {
        #expect(wrappedTerminalLineCount(displayWidth: 20, terminalColumns: 20) == 1)
        #expect(wrappedTerminalLineCount(displayWidth: 21, terminalColumns: 20) == 2)
    }

    @Test
    func renderedInputStateKeepsCursorOnBoundaryWithoutTrailingContent() {
        let state = terminalRenderedInputState(
            promptDisplayWidth: 18,
            input: "ab",
            cursorPosition: 2,
            terminalColumns: 20
        )

        #expect(state.totalLineCount == 1)
        #expect(state.cursorLineOffset == 0)
        #expect(state.cursorColumn == 20)
    }

    @Test
    func renderedInputStateWrapsBoundaryCursorWhenTrailingContentExists() {
        let state = terminalRenderedInputState(
            promptDisplayWidth: 18,
            input: "abc",
            cursorPosition: 2,
            terminalColumns: 20
        )

        #expect(state.totalLineCount == 2)
        #expect(state.cursorLineOffset == 1)
        #expect(state.cursorColumn == 1)
    }

    @Test
    func incrementalAppendIsAllowedForTailInsertion() {
        #expect(
            canIncrementallyAppendInput(
                previousInput: "hello",
                previousCursorPosition: 5,
                insertedText: " world"
            )
        )
        #expect(
            canIncrementallyAppendInput(
                previousInput: "ni",
                previousCursorPosition: 2,
                insertedText: "你好"
            )
        )
    }

    @Test
    func incrementalAppendFallsBackForMidLineOrControlInput() {
        #expect(
            !canIncrementallyAppendInput(
                previousInput: "hello",
                previousCursorPosition: 2,
                insertedText: "X"
            )
        )
        #expect(
            !canIncrementallyAppendInput(
                previousInput: "hello",
                previousCursorPosition: 5,
                insertedText: "\t"
            )
        )
    }

    @Test
    func sandboxShellSupportsExitAndStyledFallback() {
        let viewport = InMemoryTerminalViewport(
            columns: 80,
            rows: 24,
            widthPixels: 0,
            heightPixels: 0
        )

        switch defaultSandboxShell.processCommand(
            "exit",
            username: "tester",
            terminalSize: viewport
        ) {
        case .exit:
            break

        default:
            Issue.record("expected sandbox shell exit command to terminate the session")
        }

        if case let .output(message) = defaultSandboxShell.processCommand(
            "missing-command",
            username: "tester",
            terminalSize: viewport
        ) {
            #expect(message.contains("\u{1B}["))
            #expect(message.contains("missing-command"))
        } else {
            Issue.record("expected fallback command result to produce output")
        }
    }
}
