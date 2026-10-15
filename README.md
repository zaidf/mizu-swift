# Mizu for iOS

Shake your phone, Claude sees what happened. Mizu is a small Swift package for solo iOS developers: shake while
testing your own app, and your coding agent gets a screenshot, your note or voice note, device and build info, a
timeline of the last few minutes, and the app's LLM calls, over MCP.

Setup (account, MCP, app key) is at [mizu.dance](https://mizu.dance). The easiest way is to tell Claude Code
"Set me up with Mizu: https://mizu.dance/agents.txt". It follows those instructions.

iOS 16+ (macOS 13+ builds, for tests). Swift 5.10+.

## Install

Xcode: File → Add Package Dependencies… → `https://github.com/zaidf/mizu-swift` → Up to Next Major from `0.1.0`
→ add the `Mizu` library to your app target.

Or in `Package.swift`:

```swift
.package(url: "https://github.com/zaidf/mizu-swift", from: "0.1.0"),
// target dependency: .product(name: "Mizu", package: "mizu-swift")
```

## Start it (debug builds only)

```swift
import Mizu

@main
struct MyApp: App {
    init() {
        #if DEBUG
        Mizu.start(key: "mizu_ik_…")   // the app's ingest key, never the mizu_sk_ account token
        #endif
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

Shake to report, or call `Mizu.showReporter()` / `Mizu.report(note:)` yourself. Reports wait in an on-disk outbox
and upload when the network is back. Mizu does nothing in Release builds unless you set
`Options.enableInRelease`.

**Voice notes:** add `NSMicrophoneUsageDescription` to your Info.plist (e.g. "Record a voice note for a bug
report."). Without it Mizu hides the "hold to talk" button, because iOS would crash on the mic prompt.

**Which commit:** optional, add a Run Script build phase after "Copy Bundle Resources":

```sh
/usr/libexec/PlistBuddy -c "Set :MizuGitSHA $(git rev-parse --short HEAD)" "$TARGET_BUILD_DIR/$INFOPLIST_PATH" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :MizuGitSHA string $(git rev-parse --short HEAD)" "$TARGET_BUILD_DIR/$INFOPLIST_PATH"
```

## Timeline

Mizu keeps a rolling 10-minute timeline (screens, taps, keyboard, text focus, network requests, app lifecycle)
and attaches it to every report. Make it better with:

```swift
ChatView().mizuScreen("Chat")                                    // name SwiftUI screens
Mizu.log("built context", tag: "llm", data: ["messages": 12])    // your own breadcrumbs
Mizu.debug("history before send", tag: "context", data: ["count": history.count])
```

`Mizu.debug` lines cost nothing until Claude turns their tag on with the `set_capture` MCP tool. The app picks
that up on next launch or return to the foreground, no rebuild, and it expires after 24h.

## LLM calls

Record what your app actually sends, so Claude can check the context and timing:

```swift
let call = Mizu.llm(model: "claude-sonnet-5-5", system: systemPrompt, messages: history.map { .user($0) })
call.firstToken()                                                  // when streaming starts (optional)
call.finish(output: reply, inputTokens: 1200, outputTokens: 300)   // or call.fail(error)
```

Or wrap a request: `try await Mizu.traceLLM(model:messages:output:) { try await client.send(...) }`.
The last 30 calls (about 2M characters) stay on the phone and go with reports. Set
`Options.recordLLMContent = false` to keep only model, timing and token counts.

## Feature gaps

If your app has an AI chat, let it pass on things users want that the app can't do yet:

```swift
// 1. system prompt: yourPrompt + "\n\n" + FeatureGap.systemPrompt
// 2. tools: [FeatureGap.anthropicTool]   (or FeatureGap.openAITool)
// 3. when the model calls FeatureGap.toolName:
let result = Mizu.handleFeatureGap(input: toolUse.input, conversation: history)   // send back as the tool result
```

Claude sees them with `list_requests` / `get_request`.

## Never recorded

Anything typed (secure fields included), keyboard key taps, URL query strings, and request/response bodies. Reports
only go to the Mizu app you started with that ingest key.

## Tests

```bash
swift test
```

## License

MIT
