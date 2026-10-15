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

Shake to report, or call `Mizu.showReporter()` / `Mizu.report(note:)` yourself. For a bug button of your own:

```swift
if Mizu.isRunning { Button { Mizu.showReporter() } label: { Image(systemName: "ladybug") } }
```

The timeline records what opened the sheet (`shake`, `button`, or your own `trigger:`). The sheet's **+ photos**
attaches up to 5 pictures from the camera roll, e.g. a mockup or a screenshot from another app; there's no
photo-library permission prompt, since the app only gets the photos you pick, and location and other metadata
are stripped. Reports wait in an on-disk outbox and upload when the network is back. Mizu does nothing in Release builds unless you set
`Options.enableInRelease`.

**Voice notes:** add `NSMicrophoneUsageDescription` to your Info.plist (e.g. "Record a voice note for a bug
report."). Without it Mizu hides the "hold to talk" button, because iOS would crash on the mic prompt.

**Which commit:** optional, add a Run Script build phase after "Copy Bundle Resources":

```sh
/usr/libexec/PlistBuddy -c "Set :MizuGitSHA $(git rev-parse --short HEAD)" "$TARGET_BUILD_DIR/$INFOPLIST_PATH" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :MizuGitSHA string $(git rev-parse --short HEAD)" "$TARGET_BUILD_DIR/$INFOPLIST_PATH"
```

Newer Xcode projects sandbox build scripts (`ENABLE_USER_SCRIPT_SANDBOXING = YES`), which can stop `git` from
reading `.git`; the script then fails quietly and reports just lack a commit. Set it to `NO` for the app target if
you want the commit (scripts then run unsandboxed), or skip this step.

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

## Your own steps, files, and "Share debug"

Record the app's own pipeline steps under their own kinds, so Claude can filter to them:

```swift
Mizu.event("pipeline.retrieve", data: ["query": q, "chunks": 8, "ms": 412])
```

Send files with every report, the shake included, instead of building a debug zip:

```swift
Mizu.attachments = { [MizuAttachment(name: "pipeline.log", text: Pipeline.shared.log)] }
```

And make a "Share debug" button one call. It sends the screenshot, timeline, LLM calls, `Mizu.attachments`, and
any files you pass. Pass the LLM call it's about, and Claude opens that turn first:

```swift
Mizu.shareDebug(note: "turn \(turn.id)",
                attachments: [MizuAttachment(name: "turn.json", text: dump)],   // or MizuAttachment(name:json:) / (fileURL:)
                llmCall: turn.call)
```

Limits: 20 files, 10 MB each, 25 MB per report (extras are left out and noted in the timeline). Claude reads text
attachments a page or a search at a time with `get_attachment`, so long logs don't get cut off.

## LLM calls

Record what your app actually sends, so Claude can check the context and timing:

```swift
let call = Mizu.llm(model: "claude-sonnet-5-5", system: systemPrompt, messages: history.map { .user($0) })
call.firstToken()                                                  // when streaming starts (optional)
call.finish(output: reply, inputTokens: 1200, outputTokens: 300)   // or call.fail(error)
```

Or wrap a request: `try await Mizu.traceLLM(model:messages:output:) { try await client.send(...) }`.
The last 30 calls (about 2M characters) stay on the phone and go with reports.

Full prompts and replies are recorded in debug builds (you testing your own app) and **off in release builds**
(`enableInRelease`, where they'd be other people's conversations). `Options.recordLLMContent` overrides that:
`false` keeps only model, timing and token counts everywhere, `true` records text in release builds too.

## Feature gaps

If your app has an AI chat, let it pass on things users want that the app can't do yet:

```swift
// 1. system prompt: yourPrompt + "\n\n" + FeatureGap.systemPrompt
// 2. tools: [FeatureGap.anthropicTool]   (or FeatureGap.openAITool)
// 3. when the model calls FeatureGap.toolName:
let result = Mizu.handleFeatureGap(input: toolUse.input, conversation: history)   // send back as the tool result
```

Each one becomes a report filed by the app's AI, alongside the ones you shake in: Claude sees them with `list_reports {from: "ai"}`.

`FeatureGap.systemPrompt` adds exactly this to your prompt: *"If the user asks for something you or this app can't
do yet, don't pretend and don't just say no. If it isn't clear what they want or why, ask one or two short
questions first. Then call report_unsupported_request and tell them, in a sentence, that you've passed it on to
the developer."* The last 12 messages of the conversation go with each request.

## Closing the loop

When Claude marks a report done (`update_report`), whether it fixed a bug or built something someone asked for,
the install that sent it shows a small card once, the next time it opens:

    FIXED
    Hotel photos load instantly now.
    you reported: "hotel photos take seconds to load"

With `fixed_in_build`, it waits until the app's `CFBundleVersion` is that build or later, so nobody is told about a
fix they don't have yet. Nothing to set up: each install gets a random ID (`Application Support/Mizu/install-id`,
not tied to the person or device) that goes with its reports and requests, and the card appears on check-in.

## Network

Mizu sees URLSession requests by replacing `URLSessionTask.resume` (on Foundation's concrete task classes) with a
version that notes the request and then calls the original, and by observing each task's `state`. It only
watches: it's never in the data path, so it can't change or break responses, streaming included. It records method,
host, path, status, size and duration. Path segments that look like emails, UUIDs or long ids are replaced
(`/users/jane@x.com/orders/48213` → `/users/:email/orders/:id`). To leave hosts out entirely:

```swift
var options = Mizu.Options()
options.ignoredHosts = ["auth.example.com"]   // subdomains included
```

## Never recorded

Anything typed (secure fields included), keyboard key taps, URL query strings, request headers and bodies. Reports
only go to the Mizu app you started with that ingest key. What's stored and how to delete it:
[mizu.dance/privacy](https://mizu.dance/privacy).

## Tests

```bash
swift test
```

## License

MIT
