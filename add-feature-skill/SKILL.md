---
name: add-feature-skill
description: >
  Guide for adding new features to CodexPilot. Covers architecture,
  extension points, patterns, and build process.
---

## Overview

CodexPilot is a macOS menu bar app that provides a full-featured Codex app-server dashboard with a Slack-style UI, showing all threads, messages, command executions, and file changes -- plus a "Fairy Garden" that personifies threads as fairies with deterministic names, colors, and emojis.

## Architecture

CodexPilot is a single-file SwiftUI app (`CodexPilot.swift`, ~2551 lines). The `@main` struct `CodexPilotApp` provides two scenes: a `MenuBarExtra(.window)` for the menu bar panel and a `Window` for a popout window. Both render the same `SlackLayoutView` with an `isPopout` flag controlling dimensions.

A single `@Observable` class owns all mutable state:

- **`CodexConnection`** (~780 lines) -- manages the persistent WebSocket connection to the Codex server, handles JSON-RPC 2.0 protocol (initialize, thread/list, thread/start, turn/start, streaming deltas, auto-approve), maintains thread list and detail state, fairy garden state, rate limit tracking, and event log.

The connection is held as `@State` on the App struct and passed into `SlackLayoutView`. The Slack-style layout uses a sidebar + content area router pattern with `ContentMode` enum driving which content panel is shown.

## Key Types

| Type | Kind | Description |
|------|------|-------------|
| `CodexThread` | struct | Thread with id, name, status, archived flag, model, token usage, cwd, createdAt |
| `ServerEvent` | struct | Timestamped event log entry with method and summary |
| `DisplayItem` | struct | Rendered message/command/file-change item within a thread detail view |
| `FairyIdentity` | struct | Deterministic name, SF Symbol emoji, color, and colorName for a thread |
| `FairyState` | enum | Thread personification states: sleeping, idle, thinking, working, waiting, done, error |
| `FairyPreview` | struct | Fairy card data: identity, state, preview text, thread name, token usage, activity |
| `ContentMode` | enum | Router: `.empty`, `.threadDetail`, `.fairyGarden`, `.eventLog` |
| `DisplayRow` | enum | Union type for turn dividers and message rows in thread detail |
| `SlackTheme` | enum | Static color and dimension constants for the Slack-style dark theme |
| `FairyIdentityGenerator` | struct | Deterministic fairy name/color/emoji generation from thread ID hash |
| `RawWebSocket` | class | NWConnection-based WebSocket client (shared pattern across apps) |
| `CodexConnection` | @Observable class | Core state manager: WebSocket, JSON-RPC, threads, fairies, events, rate limits |
| `SlackLayoutView` | View | Root Slack-style HSplitView with sidebar + content area |
| `SidebarView` | View | Collapsible thread list and fairy list with search and actions |
| `SidebarChannelRow` | View | Thread row in sidebar with status indicator and unread styling |
| `SidebarFairyRow` | View | Fairy row in sidebar with state dot and preview text |
| `ContentAreaView` | View | Router view that switches on `ContentMode` |
| `ThreadDetailContent` | View | Full thread view with messages, command results, file changes, and composer |
| `SlackMessageRow` | View | Individual message bubble with fairy identity, timestamp, markdown rendering |
| `TurnDivider` | View | Visual separator between conversation turns |
| `FairyGardenContent` | View | Spatial canvas showing all fairies as animated orbs |
| `FairyOrb` | View | Individual fairy visualization with pulsing animation based on state |
| `EventLogContent` | View | Scrollable list of all server events |
| `EventRow` | View | Single event log entry with timestamp and method badge |

## How to Add a Feature

1. **If adding a new content panel** (e.g., settings, analytics, file browser):
   - Add a case to `ContentMode` (e.g., `.settings`).
   - Create a new view struct (e.g., `SettingsContent: View`) in the views section.
   - Add the case to `ContentAreaView`'s switch statement.
   - Add a sidebar button/row in `SidebarView` that sets `connection.contentMode = .settings`.

2. **If adding new Codex interactions** (e.g., new commands, file operations):
   - Add a method to `CodexConnection` that calls `sendRequest(method:params:)`.
   - Handle the response in `handleMessage(_:)` by matching the method name.
   - Expose results as published properties on `CodexConnection`.

3. **If adding new sidebar sections**:
   - Add a collapsible section in `SidebarView` following the existing pattern (header row with chevron, `@State` collapsed toggle, animated disclosure).

4. **If adding new fairy features**:
   - Extend `FairyPreview` with new properties.
   - Update `FairyIdentityGenerator` if new visual attributes are needed.
   - Modify `FairyOrb` or `FairyGardenContent` for new visualizations.
   - Update fairy state transitions in `CodexConnection.updateFairyState()`.

5. **If adding state to `CodexConnection`**:
   - Add properties in the appropriate section (thread state, detail state, fairy state, rate limits).
   - Update `resetState()` if the new state should clear on disconnect.

6. **Build and test** with `bash build.sh` then `open CodexPilot.app`.

## Extension Points

- **New ContentMode cases** -- add panels to the Slack-style content area router (settings, analytics, file browser, diff viewer)
- **New sidebar sections** -- add collapsible groups below threads and fairies (e.g., pinned threads, recent files, bookmarks)
- **New Codex interactions** -- use `sendRequest(method:params:)` to call any JSON-RPC 2.0 method on the Codex server; handle responses in `handleMessage(_:)`
- **New fairy features** -- extend `FairyIdentityGenerator` with new visual attributes, add fairy actions (summon, dismiss, rename), enhance `FairyOrb` animations
- **New message types** -- extend `DisplayItem` and `SlackMessageRow` to render additional content types (images, diffs, charts, interactive elements)
- **New event types** -- extend `ServerEvent` and `EventRow` to capture and display additional Codex notifications
- **Popout window features** -- the dual-scene architecture (menu bar + popout) means features work in both contexts; use the `isPopout` flag for layout differences

## Conventions

- **Theme**: All colors and dimensions come from `SlackTheme` static properties. Sidebar uses aubergine tones (`sidebarBG`, `sidebarHover`), content area uses dark tones (`contentBG`, `contentText`). Standard dimensions: `sidebarWidth: 220`, `menuBarWidth: 660`, `menuBarHeight: 500`.
- **WebSocket/JSON-RPC**: `RawWebSocket` handles raw TCP + WebSocket framing. JSON-RPC 2.0 protocol flow: `initialize` --> `thread/list` for existing threads, `thread/start` to create, `turn/start` to send prompts. Streaming responses arrive as `item/agentMessage/delta` notifications. Requests tracked via `pendingRequests: [Int: String]` with sequential integer IDs from `requestId`.
- **SF Symbols**: Used extensively for status indicators (`circle.dotted` disconnected, `wand.and.stars` active fairies, `bolt.fill` active turn, `checkmark.circle.fill` connected). Fairy emojis are SF Symbol names from `FairyIdentityGenerator`.
- **Fairy identity**: Deterministic -- same thread ID always produces the same name/color/emoji via hash-based selection from curated arrays. This ensures visual consistency across sessions.
- **State machines**: `FairyState` drives fairy visualizations. Connection state drives the menu bar icon. `ContentMode` drives the content area router. All use enum-based switching.
- **Dual scene**: Both `MenuBarExtra` and `Window` scenes share the same `CodexConnection` instance. Use `isPopout` to vary layout (e.g., larger dimensions for the popout window).
- **Auto-approve**: CodexPilot automatically approves Codex action requests via the `confirmationResponse` JSON-RPC method, enabling hands-free operation.

## Build & Test

```bash
bash build.sh            # Compiles CodexPilot.swift with -O and creates .app bundle
open CodexPilot.app      # Run the app (appears in menu bar)
```

Requires macOS 14.0+ and Xcode command-line tools. The app runs as `LSUIElement` (no Dock icon). Codex app-server must be running (default `ws://127.0.0.1:8080`) for full functionality. A mock server (`test_mock_server.py`) is included for development testing.
