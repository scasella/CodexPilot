#!/usr/bin/env python3
"""Mock Codex app server for testing CodexPilot v0.3.0.

Runs a WebSocket server on ws://127.0.0.1:8080 that responds to JSON-RPC
requests like the real codex-app-server would. Supports thread lifecycle
(create, archive, unarchive, rename), account info, rate limits, turn
streaming, and approval requests.

Usage: python3 test_mock_server.py
"""

import asyncio
import json
import time
import random
import uuid

try:
    import websockets
except ImportError:
    print("Install websockets: pip3 install websockets")
    exit(1)

MOCK_THREADS = [
    {
        "id": "thread-001-abc",
        "name": "Fix authentication bug",
        "cwd": "/Users/dev/myproject",
        "archived": False,
        "modelProvider": "openai",
        "createdAt": int(time.time()) - 3600,
        "updatedAt": int(time.time()) - 1800,
        "status": {"type": "idle"},
        "preview": "Fix the login bug",
        "cliVersion": "0.1.0",
        "source": "cli",
    },
    {
        "id": "thread-002-def",
        "name": "Add unit tests for parser",
        "cwd": "/Users/dev/parser",
        "archived": False,
        "modelProvider": "openai",
        "createdAt": int(time.time()) - 7200,
        "updatedAt": int(time.time()) - 3600,
        "status": {"type": "idle"},
        "preview": "Write tests",
        "cliVersion": "0.1.0",
        "source": "cli",
    },
    {
        "id": "thread-003-ghi",
        "name": "Refactor database layer",
        "cwd": "/Users/dev/database",
        "archived": False,
        "modelProvider": "anthropic",
        "createdAt": int(time.time()) - 86400,
        "updatedAt": int(time.time()) - 43200,
        "status": {"type": "idle"},
        "preview": "Refactor DB",
        "cliVersion": "0.1.0",
        "source": "cli",
    },
]

ARCHIVED_THREADS = [
    {
        "id": "thread-004-old",
        "name": "Old migration script",
        "cwd": "/Users/dev/migrations",
        "archived": True,
        "modelProvider": "openai",
        "createdAt": int(time.time()) - 172800,
        "updatedAt": int(time.time()) - 172800,
        "status": {"type": "notLoaded"},
        "preview": "DB migration",
        "cliVersion": "0.1.0",
        "source": "cli",
    },
]

LOADED_THREAD_IDS = ["thread-001-abc", "thread-002-def"]

MOCK_TURNS = {
    "thread-001-abc": [
        {
            "id": "turn-1",
            "items": [
                {"id": "item-1a", "type": "userMessage", "content": [{"type": "text", "text": "Fix the login bug where users get 401 after token refresh"}]},
                {"id": "item-1b", "type": "agentMessage", "text": "I'll investigate the authentication flow. Let me start by looking at the token refresh logic."},
                {"id": "item-1c", "type": "commandExecution", "command": "grep -r 'refreshToken' src/auth/", "status": "completed", "exitCode": 0, "aggregatedOutput": "src/auth/token.ts:42: async refreshToken()"},
                {"id": "item-1d", "type": "fileChange", "status": "completed", "changes": [{"path": "src/auth/token.ts"}, {"path": "src/auth/middleware.ts"}]},
                {"id": "item-1e", "type": "agentMessage", "text": "I found the issue. The token refresh was not properly updating the Authorization header. I've fixed it in both files."},
            ]
        },
    ],
    "thread-002-def": [
        {
            "id": "turn-2",
            "items": [
                {"id": "item-2a", "type": "userMessage", "content": [{"type": "text", "text": "Write tests for the JSON parser module"}]},
                {"id": "item-2b", "type": "reasoning", "summary": ["Need to test edge cases: empty input, nested objects, unicode strings"]},
                {"id": "item-2c", "type": "agentMessage", "text": "I'll create comprehensive tests for the JSON parser covering edge cases."},
            ]
        },
    ],
    "thread-003-ghi": [],
}

# Rate limit state
rate_limit_used = 35
rate_limit_window_mins = 300
rate_limit_resets_at = int(time.time()) + 10800


async def handle_client(websocket):
    global rate_limit_used
    print(f"[+] Client connected from {websocket.remote_address}")
    try:
        async for raw in websocket:
            msg = json.loads(raw)
            method = msg.get("method", "")
            msg_id = msg.get("id")
            params = msg.get("params", {})
            print(f"  <- {method} (id={msg_id})")

            if method == "initialize":
                resp = {"id": msg_id, "result": {"userAgent": "codex-app-server/0.1.0-mock"}}
                await websocket.send(json.dumps(resp))
                print(f"  -> initialize response")

            elif method == "thread/list":
                show_archived = params.get("showArchived", False)
                threads = list(MOCK_THREADS)
                if show_archived:
                    threads.extend(ARCHIVED_THREADS)
                resp = {"id": msg_id, "result": {"data": threads, "nextCursor": None}}
                await websocket.send(json.dumps(resp))
                print(f"  -> {len(threads)} threads (showArchived={show_archived})")

            elif method == "thread/loaded/list":
                loaded = [{"id": tid} for tid in LOADED_THREAD_IDS]
                resp = {"id": msg_id, "result": {"data": loaded, "nextCursor": None}}
                await websocket.send(json.dumps(resp))
                print(f"  -> {len(LOADED_THREAD_IDS)} loaded threads")

            elif method == "thread/start":
                new_id = f"thread-{uuid.uuid4().hex[:8]}"
                new_thread = {
                    "id": new_id,
                    "name": None,
                    "cwd": "/Users/dev/workspace",
                    "archived": False,
                    "modelProvider": "openai",
                    "createdAt": int(time.time()),
                    "updatedAt": int(time.time()),
                    "status": {"type": "idle"},
                    "preview": "",
                    "cliVersion": "0.1.0",
                    "source": "appServer",
                    "turns": [],
                }
                MOCK_THREADS.insert(0, new_thread)
                LOADED_THREAD_IDS.append(new_id)
                MOCK_TURNS[new_id] = []
                resp = {
                    "id": msg_id,
                    "result": {
                        "thread": new_thread,
                        "model": "o4-mini",
                        "modelProvider": "openai",
                        "cwd": "/Users/dev/workspace",
                        "approvalPolicy": "auto-edit",
                        "sandbox": {"type": "dangerFullAccess"},
                    }
                }
                await websocket.send(json.dumps(resp))
                # Send thread/started notification
                notif = {"method": "thread/started", "params": {"thread": new_thread}}
                await websocket.send(json.dumps(notif))
                print(f"  -> created new thread {new_id}")

            elif method == "thread/resume":
                thread_id = params.get("threadId", "")
                thread = next((t for t in MOCK_THREADS if t["id"] == thread_id), None)
                turns = MOCK_TURNS.get(thread_id, [])
                resp = {
                    "id": msg_id,
                    "result": {
                        "thread": {
                            "id": thread_id,
                            "name": thread["name"] if thread else "Unknown",
                            "turns": turns,
                        },
                        "modelProvider": thread.get("modelProvider", "openai") if thread else "openai",
                    }
                }
                await websocket.send(json.dumps(resp))
                if thread_id not in LOADED_THREAD_IDS:
                    LOADED_THREAD_IDS.append(thread_id)
                print(f"  -> resumed {thread_id} ({len(turns)} turns)")

            elif method == "thread/archive":
                thread_id = params.get("threadId", "?")
                thread = next((t for t in MOCK_THREADS if t["id"] == thread_id), None)
                if thread:
                    MOCK_THREADS.remove(thread)
                    thread["archived"] = True
                    ARCHIVED_THREADS.append(thread)
                resp = {"id": msg_id, "result": {}}
                await websocket.send(json.dumps(resp))
                notif = {"method": "thread/archived", "params": {"threadId": thread_id}}
                await websocket.send(json.dumps(notif))
                print(f"  -> archived {thread_id}")

            elif method == "thread/unarchive":
                thread_id = params.get("threadId", "?")
                thread = next((t for t in ARCHIVED_THREADS if t["id"] == thread_id), None)
                if thread:
                    ARCHIVED_THREADS.remove(thread)
                    thread["archived"] = False
                    MOCK_THREADS.append(thread)
                resp = {
                    "id": msg_id,
                    "result": {"thread": thread} if thread else {}
                }
                await websocket.send(json.dumps(resp))
                notif = {"method": "thread/unarchived", "params": {"threadId": thread_id}}
                await websocket.send(json.dumps(notif))
                print(f"  -> unarchived {thread_id}")

            elif method == "thread/name/set":
                thread_id = params.get("threadId", "?")
                new_name = params.get("name", "Unnamed")
                for t in MOCK_THREADS:
                    if t["id"] == thread_id:
                        t["name"] = new_name
                resp = {"id": msg_id, "result": {}}
                await websocket.send(json.dumps(resp))
                notif = {"method": "thread/name/updated", "params": {"threadId": thread_id, "threadName": new_name}}
                await websocket.send(json.dumps(notif))
                print(f"  -> renamed {thread_id} to '{new_name}'")

            elif method == "account/read":
                resp = {
                    "id": msg_id,
                    "result": {
                        "account": {
                            "type": "chatgpt",
                            "email": "dev@example.com",
                            "planType": "pro",
                        },
                        "requiresOpenaiAuth": False,
                    }
                }
                await websocket.send(json.dumps(resp))
                print(f"  -> account info (pro)")

            elif method == "account/rateLimits/read":
                resp = {
                    "id": msg_id,
                    "result": {
                        "rateLimits": {
                            "limitId": "limit-001",
                            "limitName": "codex-pro",
                            "primary": {
                                "usedPercent": rate_limit_used,
                                "windowDurationMins": rate_limit_window_mins,
                                "resetsAt": rate_limit_resets_at,
                            },
                            "secondary": None,
                            "credits": {
                                "hasCredits": True,
                                "unlimited": False,
                                "balance": "$42.50",
                            },
                            "planType": "pro",
                        },
                        "rateLimitsByLimitId": None,
                    }
                }
                await websocket.send(json.dumps(resp))
                print(f"  -> rate limits ({rate_limit_used}% used)")

            elif method == "turn/start":
                thread_id = params.get("threadId", "")
                resp = {"id": msg_id, "result": {}}
                await websocket.send(json.dumps(resp))
                print(f"  -> turn/start ack")
                asyncio.create_task(simulate_turn(websocket, thread_id, params.get("input", [])))

            elif method == "turn/interrupt":
                resp = {"id": msg_id, "result": {}}
                await websocket.send(json.dumps(resp))
                notif = {"method": "turn/completed", "params": {"threadId": params.get("threadId")}}
                await websocket.send(json.dumps(notif))
                print(f"  -> interrupted")

            else:
                resp = {"id": msg_id, "result": {}}
                await websocket.send(json.dumps(resp))
                print(f"  -> empty result for {method}")

    except Exception as e:
        print(f"[-] Client disconnected: {e}")


async def simulate_turn(ws, thread_id, input_items):
    """Simulate a full turn with streaming agent response."""
    global rate_limit_used
    await asyncio.sleep(0.3)

    # Send turn/started
    notif = {"method": "turn/started", "params": {"threadId": thread_id}}
    await ws.send(json.dumps(notif))
    print(f"  ~> turn/started")

    # Status change to active
    status_notif = {"method": "thread/status/changed", "params": {"threadId": thread_id, "status": {"type": "active", "activeFlags": []}}}
    await ws.send(json.dumps(status_notif))

    await asyncio.sleep(0.5)

    # Send item/started for agent message
    agent_item_id = f"agent-{uuid.uuid4().hex[:8]}"
    turn_id = f"turn-{uuid.uuid4().hex[:8]}"
    item_started = {
        "method": "item/started",
        "params": {
            "threadId": thread_id,
            "turnId": turn_id,
            "item": {"id": agent_item_id, "type": "agentMessage", "text": ""},
        }
    }
    await ws.send(json.dumps(item_started))
    print(f"  ~> item/started (agentMessage)")

    # Stream deltas
    response_text = "I'll help you with that. Let me analyze the code and make the necessary changes."
    words = response_text.split(" ")
    for i, word in enumerate(words):
        delta = word + (" " if i < len(words) - 1 else "")
        delta_notif = {
            "method": "item/agentMessage/delta",
            "params": {"threadId": thread_id, "itemId": agent_item_id, "delta": delta}
        }
        await ws.send(json.dumps(delta_notif))
        await asyncio.sleep(0.08)

    # Complete the agent message item
    item_completed = {
        "method": "item/completed",
        "params": {
            "threadId": thread_id,
            "turnId": turn_id,
            "item": {"id": agent_item_id, "type": "agentMessage", "text": response_text},
        }
    }
    await ws.send(json.dumps(item_completed))

    await asyncio.sleep(0.3)

    # Simulate a command execution with approval request
    approval_req = {
        "id": random.randint(1000, 9999),
        "method": "commandExecution/requestApproval",
        "params": {
            "threadId": thread_id,
            "command": {"command": "grep -r 'TODO' src/"},
        }
    }
    await ws.send(json.dumps(approval_req))
    print(f"  ~> commandExecution/requestApproval (id={approval_req['id']})")

    await asyncio.sleep(1.0)

    # Command item started
    cmd_item_id = f"cmd-{uuid.uuid4().hex[:8]}"
    cmd_started = {
        "method": "item/started",
        "params": {
            "threadId": thread_id,
            "turnId": turn_id,
            "item": {"id": cmd_item_id, "type": "commandExecution", "command": "grep -r 'TODO' src/", "status": "inProgress"},
        }
    }
    await ws.send(json.dumps(cmd_started))

    await asyncio.sleep(0.5)

    # Command completed
    cmd_completed = {
        "method": "item/completed",
        "params": {
            "threadId": thread_id,
            "turnId": turn_id,
            "item": {
                "id": cmd_item_id,
                "type": "commandExecution",
                "command": "grep -r 'TODO' src/",
                "status": "completed",
                "exitCode": 0,
                "aggregatedOutput": "src/main.ts:15: // TODO: refactor this\nsrc/utils.ts:8: // TODO: add validation",
            },
        }
    }
    await ws.send(json.dumps(cmd_completed))

    await asyncio.sleep(0.3)

    # Update rate limit usage
    rate_limit_used = min(100, rate_limit_used + random.randint(2, 7))
    rate_notif = {
        "method": "account/rateLimits/updated",
        "params": {
            "rateLimits": {
                "limitId": "limit-001",
                "limitName": "codex-pro",
                "primary": {
                    "usedPercent": rate_limit_used,
                    "windowDurationMins": rate_limit_window_mins,
                    "resetsAt": rate_limit_resets_at,
                },
                "planType": "pro",
            }
        }
    }
    await ws.send(json.dumps(rate_notif))
    print(f"  ~> rate limit updated: {rate_limit_used}%")

    # Token usage update
    usage_notif = {
        "method": "thread/tokenUsage/updated",
        "params": {
            "threadId": thread_id,
            "tokenUsage": {"total": {"totalTokens": random.randint(1000, 5000)}}
        }
    }
    await ws.send(json.dumps(usage_notif))

    # Turn completed
    done_notif = {"method": "turn/completed", "params": {"threadId": thread_id}}
    await ws.send(json.dumps(done_notif))

    # Status back to idle
    status_notif = {"method": "thread/status/changed", "params": {"threadId": thread_id, "status": {"type": "idle"}}}
    await ws.send(json.dumps(status_notif))
    print(f"  ~> turn/completed")


async def main():
    print("CodexPilot v0.3.0 Mock Server starting on ws://127.0.0.1:8080")
    print("Supports: initialize, thread/list, thread/loaded/list, thread/resume,")
    print("          thread/start, thread/archive, thread/unarchive, thread/name/set,")
    print("          account/read, account/rateLimits/read, turn/start (streaming),")
    print("          turn/interrupt + account/rateLimits/updated notifications")
    print("Press Ctrl+C to stop\n")
    server = await websockets.serve(handle_client, "127.0.0.1", 8080, compression=None)
    await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())
