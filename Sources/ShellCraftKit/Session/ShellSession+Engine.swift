import Foundation
import GhosttyTerminal

actor Engine {
    private enum EscapeState {
        case none
        case escape
        case csi(Data)
    }

    private let shell: ShellDefinition
    private let sessionBridge: SessionBridge
    private var startedAt = Date()
    private var currentInput = ""
    private var cursorPosition = 0
    private var isTerminated = false
    private var pendingText = Data()
    private var escapeState = EscapeState.none
    private var ignoreNextLineFeed = false
    private var hasStarted = false
    private var commandHistory: [String] = []
    private var historyIndex = -1
    private var savedInput = ""
    private var pendingResizeRedrawTask: Task<Void, Never>?
    private var renderedInputRevision: UInt64 = 0
    private var renderedInputState = TerminalRenderedInputState(
        totalLineCount: 1,
        cursorLineOffset: 0,
        cursorColumn: 1
    )
    private var terminalSize = InMemoryTerminalViewport(
        columns: 80,
        rows: 20,
        widthPixels: 0,
        heightPixels: 0
    )

    init(shell: ShellDefinition, sessionBridge: SessionBridge) {
        self.shell = shell
        self.sessionBridge = sessionBridge
    }

    func start() {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        isTerminated = false
        startedAt = Date()
        send("\u{1B}[2J\u{1B}[H")
        send(shell.welcomeMessage)
        sendPrompt()
    }

    func updateSize(_ size: InMemoryTerminalViewport) {
        let previous = terminalSize
        terminalSize = size

        shellDebugLog(
            .metrics,
            "shell resize cols=\(previous.columns)x\(previous.rows) -> \(size.columns)x\(size.rows) pixels=\(size.widthPixels)x\(size.heightPixels)"
        )

        guard hasStarted, !isTerminated else { return }
        guard previous != size else { return }

        shellDebugLog(
            .actions,
            "shell redraw after resize input=\(shellDebugDescribe(currentInput)) cursorPosition=\(cursorPosition)"
        )
        redrawInputLine()

        pendingResizeRedrawTask?.cancel()
        let expectedRevision = renderedInputRevision
        pendingResizeRedrawTask = Task { [self] in
            try? await Task.sleep(nanoseconds: 75_000_000)
            guard !Task.isCancelled else { return }
            redrawInputLineIfViewportStable(
                size,
                expectedRevision: expectedRevision
            )
        }
    }

    func handleOutbound(_ data: Data) {
        guard !isTerminated else {
            return
        }

        for byte in data {
            handle(byte)
        }
        flushPendingText()
    }

    // MARK: - Byte Handling

    private func handle(_ byte: UInt8) {
        switch escapeState {
        case .escape:
            flushPendingText()
            if byte == 0x5B {
                escapeState = .csi(Data())
            } else if byte == 0x4F {
                escapeState = .csi(Data())
            } else {
                escapeState = .none
            }
            return

        case var .csi(buffer):
            if (0x40 ... 0x7E).contains(byte) {
                escapeState = .none
                handleCSI(buffer, finalByte: byte)
            } else {
                buffer.append(byte)
                escapeState = .csi(buffer)
            }
            return

        case .none:
            break
        }

        switch byte {
        case 0x1B:
            flushPendingText()
            escapeState = .escape

        case 0x01:
            flushPendingText()
            moveCursorToStart()

        case 0x02:
            flushPendingText()
            moveCursorLeft()

        case 0x03:
            flushPendingText()
            currentInput.removeAll(keepingCapacity: true)
            cursorPosition = 0
            resetHistoryState()
            send("^C\r\n")
            sendPrompt()

        case 0x05:
            flushPendingText()
            moveCursorToEnd()

        case 0x06:
            flushPendingText()
            moveCursorRight()

        case 0x0C:
            flushPendingText()
            currentInput.removeAll(keepingCapacity: true)
            cursorPosition = 0
            resetHistoryState()
            send("\u{1B}[2J\u{1B}[H")
            sendPrompt()

        case 0x15:
            flushPendingText()
            killLine()

        case 0x08, 0x7F:
            flushPendingText()
            deleteBackward()

        case 0x0D:
            flushPendingText()
            ignoreNextLineFeed = true
            submitCurrentInput()

        case 0x0A:
            flushPendingText()
            if ignoreNextLineFeed {
                ignoreNextLineFeed = false
                return
            }

            submitCurrentInput()

        case 0x09:
            flushPendingText()
            insertText("\t")

        default:
            guard byte >= 0x20 else {
                return
            }

            pendingText.append(byte)
        }
    }

    private func handleCSI(_ params: Data, finalByte: UInt8) {
        switch finalByte {
        case 0x41: // A - Up
            navigateHistory(direction: .up)
        case 0x42: // B - Down
            navigateHistory(direction: .down)
        case 0x43: // C - Right
            moveCursorRight()
        case 0x44: // D - Left
            moveCursorLeft()
        case 0x48: // H - Home
            moveCursorToStart()
        case 0x46: // F - End
            moveCursorToEnd()
        case 0x7E: // ~ - Extended keys
            guard let param = String(data: params, encoding: .ascii) else {
                return
            }
            if param == "3" {
                deleteForward()
            }
        default:
            break
        }
    }

    // MARK: - Cursor Movement

    private func moveCursorLeft() {
        guard cursorPosition > 0 else { return }
        cursorPosition -= 1
        redrawInputLine()
    }

    private func moveCursorRight() {
        guard cursorPosition < currentInput.count else { return }
        cursorPosition += 1
        redrawInputLine()
    }

    private func moveCursorToStart() {
        guard cursorPosition > 0 else {
            return
        }
        cursorPosition = 0
        redrawInputLine()
    }

    private func moveCursorToEnd() {
        guard cursorPosition < currentInput.count else {
            return
        }
        cursorPosition = currentInput.count
        redrawInputLine()
    }

    // MARK: - Editing

    private func insertText(_ text: String) {
        let previousInput = currentInput
        let previousCursorPosition = cursorPosition
        let idx = currentInput.index(currentInput.startIndex, offsetBy: cursorPosition)
        currentInput.insert(contentsOf: text, at: idx)
        cursorPosition += text.count

        if applyIncrementalAppendIfPossible(
            insertedText: text,
            previousInput: previousInput,
            previousCursorPosition: previousCursorPosition
        ) {
            return
        }

        redrawInputLine()
    }

    private func deleteBackward() {
        guard cursorPosition > 0 else {
            return
        }

        let idx = currentInput.index(currentInput.startIndex, offsetBy: cursorPosition - 1)
        currentInput.remove(at: idx)
        cursorPosition -= 1
        redrawInputLine()
    }

    private func deleteForward() {
        guard cursorPosition < currentInput.count else {
            return
        }

        let idx = currentInput.index(currentInput.startIndex, offsetBy: cursorPosition)
        currentInput.remove(at: idx)
        redrawInputLine()
    }

    private func killLine() {
        guard !currentInput.isEmpty else {
            return
        }

        currentInput.removeAll(keepingCapacity: true)
        cursorPosition = 0
        redrawInputLine()
    }

    // MARK: - History

    private enum HistoryDirection {
        case up
        case down
    }

    private func navigateHistory(direction: HistoryDirection) {
        guard !commandHistory.isEmpty else {
            return
        }

        switch direction {
        case .up:
            if historyIndex < 0 {
                savedInput = currentInput
                historyIndex = commandHistory.count - 1
            } else if historyIndex > 0 {
                historyIndex -= 1
            } else {
                return
            }

        case .down:
            guard historyIndex >= 0 else {
                return
            }
            if historyIndex < commandHistory.count - 1 {
                historyIndex += 1
            } else {
                historyIndex = -1
                currentInput = savedInput
                cursorPosition = currentInput.count
                redrawInputLine()
                return
            }
        }

        currentInput = commandHistory[historyIndex]
        cursorPosition = currentInput.count
        redrawInputLine()
    }

    private func resetHistoryState() {
        historyIndex = -1
        savedInput = ""
    }

    // MARK: - Text Handling

    private func flushPendingText() {
        guard !pendingText.isEmpty else {
            return
        }

        guard let text = String(data: pendingText, encoding: .utf8) else {
            return
        }

        let previousInput = currentInput
        let previousCursorPosition = cursorPosition
        let idx = currentInput.index(currentInput.startIndex, offsetBy: cursorPosition)
        currentInput.insert(contentsOf: text, at: idx)
        cursorPosition += text.count
        pendingText.removeAll(keepingCapacity: true)

        if applyIncrementalAppendIfPossible(
            insertedText: text,
            previousInput: previousInput,
            previousCursorPosition: previousCursorPosition
        ) {
            return
        }

        redrawInputLine()
    }

    private func submitCurrentInput() {
        send("\r\n")

        let command = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        currentInput.removeAll(keepingCapacity: true)
        cursorPosition = 0

        if !command.isEmpty {
            commandHistory.append(command)
        }
        resetHistoryState()

        switch shell.processCommand(
            command,
            username: NSUserName(),
            terminalSize: terminalSize
        ) {
        case let .output(output):
            if !output.isEmpty {
                send(output)
            }
            sendPrompt()

        case .clear:
            send("\u{1B}[2J\u{1B}[H")
            sendPrompt()

        case .exit:
            isTerminated = true
            send("logout\r\n")
            sessionBridge.session?.finish(
                exitCode: 0,
                runtimeMilliseconds: elapsedMilliseconds
            )
        }
    }

    private func sendPrompt() {
        send(shell.prompt)
        renderedInputState = terminalRenderedInputState(
            promptDisplayWidth: shell.promptDisplayWidth,
            input: currentInput,
            cursorPosition: cursorPosition,
            terminalColumns: Int(terminalSize.columns)
        )
        renderedInputRevision &+= 1
    }

    private func redrawInputLine() {
        let nextState = terminalRenderedInputState(
            promptDisplayWidth: shell.promptDisplayWidth,
            input: currentInput,
            cursorPosition: cursorPosition,
            terminalColumns: Int(terminalSize.columns)
        )
        let renderedEndState = terminalRenderedInputState(
            promptDisplayWidth: shell.promptDisplayWidth,
            input: currentInput,
            cursorPosition: currentInput.count,
            terminalColumns: Int(terminalSize.columns)
        )
        let linesToClear = max(
            renderedInputState.totalLineCount,
            nextState.totalLineCount
        )

        shellDebugLog(
            .actions,
            "shell redraw promptWidth=\(shell.promptDisplayWidth) input=\(shellDebugDescribe(currentInput)) cursorPosition=\(cursorPosition) previousLines=\(renderedInputState.totalLineCount) nextLines=\(nextState.totalLineCount)"
        )

        moveCursorToRenderedInputStart(renderedInputState)
        clearRenderedBlock(linesToClear)
        send(shell.prompt)
        send(currentInput)
        moveCursor(
            from: renderedEndState,
            to: nextState
        )
        renderedInputState = nextState
        renderedInputRevision &+= 1
    }

    private func redrawInputLineIfViewportStable(
        _ expectedViewport: InMemoryTerminalViewport,
        expectedRevision: UInt64
    ) {
        guard hasStarted, !isTerminated else { return }
        guard terminalSize == expectedViewport else { return }
        guard renderedInputRevision == expectedRevision else {
            shellDebugLog(
                .actions,
                "shell redraw settle skipped: revision changed expected=\(expectedRevision) actual=\(renderedInputRevision)"
            )
            return
        }

        shellDebugLog(
            .actions,
            "shell redraw settle viewport=\(expectedViewport.columns)x\(expectedViewport.rows) pixels=\(expectedViewport.widthPixels)x\(expectedViewport.heightPixels)"
        )
        redrawInputLine()
    }

    private func applyIncrementalAppendIfPossible(
        insertedText: String,
        previousInput: String,
        previousCursorPosition: Int
    ) -> Bool {
        guard canIncrementallyAppendInput(
            previousInput: previousInput,
            previousCursorPosition: previousCursorPosition,
            insertedText: insertedText
        ) else {
            return false
        }

        let nextState = terminalRenderedInputState(
            promptDisplayWidth: shell.promptDisplayWidth,
            input: currentInput,
            cursorPosition: cursorPosition,
            terminalColumns: Int(terminalSize.columns)
        )

        shellDebugLog(
            .actions,
            "shell incremental append text=\(shellDebugDescribe(insertedText)) input=\(shellDebugDescribe(currentInput)) cursorPosition=\(cursorPosition)"
        )
        send(insertedText)
        renderedInputState = nextState
        renderedInputRevision &+= 1
        return true
    }

    private func moveCursorToRenderedInputStart(
        _ state: TerminalRenderedInputState
    ) {
        send("\r")
        guard state.cursorLineOffset > 0 else { return }
        send("\u{1B}[\(state.cursorLineOffset)A\r")
    }

    private func clearRenderedBlock(_ count: Int) {
        guard count > 0 else { return }
        shellDebugLog(
            .actions,
            "shell clear rendered block lines=\(count)"
        )
        send("\u{1B}[J")
    }

    private func moveCursor(
        from current: TerminalRenderedInputState,
        to target: TerminalRenderedInputState
    ) {
        let rowDelta = current.cursorLineOffset - target.cursorLineOffset
        if rowDelta > 0 {
            send("\u{1B}[\(rowDelta)A")
        } else if rowDelta < 0 {
            send("\u{1B}[\(-rowDelta)B")
        }

        send("\u{1B}[\(target.cursorColumn)G")
    }

    private func send(_ string: String) {
        sessionBridge.session?.receive(string)
    }

    private func send(_ data: Data) {
        sessionBridge.session?.receive(data)
    }

    private var elapsedMilliseconds: UInt64 {
        UInt64(max(0, Date().timeIntervalSince(startedAt) * 1000))
    }
}

func terminalCursorColumn(
    promptDisplayWidth: Int,
    input: String,
    cursorPosition: Int
) -> Int {
    terminalRenderedInputState(
        promptDisplayWidth: promptDisplayWidth,
        input: input,
        cursorPosition: cursorPosition,
        terminalColumns: .max
    ).cursorColumn
}

struct TerminalRenderedInputState: Equatable {
    let totalLineCount: Int
    let cursorLineOffset: Int
    let cursorColumn: Int
}

func terminalRenderedInputState(
    promptDisplayWidth: Int,
    input: String,
    cursorPosition: Int,
    terminalColumns: Int
) -> TerminalRenderedInputState {
    let columns = max(terminalColumns, 1)
    let clampedCursorPosition = min(max(cursorPosition, 0), input.count)
    let totalWidth = promptDisplayWidth + input.terminalDisplayWidth
    let cursorWidth = promptDisplayWidth
        + String(input.prefix(clampedCursorPosition)).terminalDisplayWidth
    let hasTrailingContent = cursorWidth < totalWidth

    let cursorLineOffset: Int
    let cursorColumn: Int

    if cursorWidth <= 0 {
        cursorLineOffset = 0
        cursorColumn = 1
    } else if cursorWidth % columns == 0, !hasTrailingContent {
        cursorLineOffset = max((cursorWidth / columns) - 1, 0)
        cursorColumn = columns
    } else {
        cursorLineOffset = cursorWidth / columns
        cursorColumn = (cursorWidth % columns) + 1
    }

    return TerminalRenderedInputState(
        totalLineCount: wrappedTerminalLineCount(
            displayWidth: totalWidth,
            terminalColumns: columns
        ),
        cursorLineOffset: cursorLineOffset,
        cursorColumn: cursorColumn
    )
}

func wrappedTerminalLineCount(
    displayWidth: Int,
    terminalColumns: Int
) -> Int {
    let columns = max(terminalColumns, 1)
    return max(1, (max(displayWidth, 1) - 1) / columns + 1)
}

func canIncrementallyAppendInput(
    previousInput: String,
    previousCursorPosition: Int,
    insertedText: String
) -> Bool {
    guard !insertedText.isEmpty else { return false }
    guard previousCursorPosition == previousInput.count else { return false }
    return insertedText.unicodeScalars.allSatisfy { scalar in
        scalar.value >= 0x20 && scalar.value != 0x7F
    }
}

private func shellDebugLog(
    _ category: TerminalDebugCategory,
    _ message: @autoclosure () -> String
) {
    guard TerminalDebugLog.isEnabled else { return }
    guard TerminalDebugLog.categories.contains(category) else { return }
    TerminalDebugLog.sink("[ShellCraftKit] \(message())")
}

private func shellDebugDescribe(_ string: String?) -> String {
    guard let string else { return "nil" }
    let truncated = String(string.prefix(96))
    let escaped = truncated
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\u{1B}", with: "\\e")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    let suffix = string.count > truncated.count ? "..." : ""
    return "\"\(escaped)\(suffix)\""
}
