"""
Sotos Controller — WebSocket relay server for ESP32 BLE HID.

Endpoints:
  GET  /          — basic service info
  GET  /health    — liveness check
  GET  /status    — check if device is connected
  POST /command   — {"command": "TYPE Hello"}
  POST /commands  — {"commands": ["TYPE Hi", "ENTER"], "delay": 0.3}
  WS   /ws        — ESP32 device channel
"""

import asyncio
import os
from datetime import datetime, timezone

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request
from fastapi.responses import JSONResponse

app = FastAPI(title="Sotos Controller")

# Connected device state
device_ws: dict[str, WebSocket] = {}
pending_responses: dict[str, asyncio.Queue] = {}


@app.get("/")
async def root():
    return {"service": "sotos-controller", "status": "running", "ws_path": "/ws"}


@app.get("/health")
async def health():
    return {"service": "sotos-controller", "status": "running"}


@app.get("/debug")
async def debug_headers(request: Request):
    return {"headers": dict(request.headers), "url": str(request.url)}


@app.get("/status")
async def status():
    return {
        "connected": len(device_ws) > 0,
        "devices": list(device_ws.keys()),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.post("/command")
async def send_command(payload: dict):
    cmd = payload.get("command", "").strip()
    if not cmd:
        return JSONResponse({"error": "missing 'command'"}, status_code=400)
    if not device_ws:
        return JSONResponse({"error": "no device connected"}, status_code=503)

    device_id = list(device_ws.keys())[0]
    ws = device_ws[device_id]
    queue = pending_responses[device_id]

    # Drain stale responses
    while not queue.empty():
        try:
            queue.get_nowait()
        except asyncio.QueueEmpty:
            break

    try:
        await ws.send_json({"type": "command", "command": cmd})
        response = await asyncio.wait_for(queue.get(), timeout=5.0)
        return {"ok": True, "command": cmd, "response": response}
    except asyncio.TimeoutError:
        return {"ok": True, "command": cmd, "response": "sent (timeout)"}
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=500)


@app.post("/commands")
async def send_commands(payload: dict):
    cmds = payload.get("commands", [])
    delay = payload.get("delay", 0.3)
    if not cmds:
        return JSONResponse({"error": "missing 'commands'"}, status_code=400)
    if not device_ws:
        return JSONResponse({"error": "no device connected"}, status_code=503)

    device_id = list(device_ws.keys())[0]
    ws = device_ws[device_id]
    queue = pending_responses[device_id]

    results = []
    for cmd in cmds:
        while not queue.empty():
            try:
                queue.get_nowait()
            except asyncio.QueueEmpty:
                break
        try:
            await ws.send_json({"type": "command", "command": cmd})
            response = await asyncio.wait_for(queue.get(), timeout=5.0)
            results.append({"command": cmd, "response": response})
        except asyncio.TimeoutError:
            results.append({"command": cmd, "response": "timeout"})
        except Exception as e:
            results.append({"command": cmd, "error": str(e)})
            break
        await asyncio.sleep(delay)

    return {"ok": True, "results": results}


async def handle_device_ws(ws: WebSocket, path: str):
    """Shared WebSocket handler for ESP32 device connections."""
    await ws.accept()
    device_id = f"esp32-{id(ws)}"
    device_ws[device_id] = ws
    pending_responses[device_id] = asyncio.Queue()
    ts = datetime.now(timezone.utc).isoformat()
    print(f"[{ts}] Device connected: {device_id} on {path}")

    try:
        while True:
            data = await ws.receive_json()
            msg_type = data.get("type", "")

            if msg_type == "heartbeat":
                await ws.send_json({"type": "heartbeat_ack"})
            elif msg_type == "response":
                await pending_responses[device_id].put(data)
            else:
                print(f"Unknown message: {data}")
    except WebSocketDisconnect:
        ts = datetime.now(timezone.utc).isoformat()
        print(f"[{ts}] Device disconnected: {device_id}")
    except Exception as e:
        ts = datetime.now(timezone.utc).isoformat()
        print(f"[{ts}] Device error: {e}")
    finally:
        device_ws.pop(device_id, None)
        pending_responses.pop(device_id, None)


@app.websocket("/ws")
async def websocket_ws(ws: WebSocket):
    await handle_device_ws(ws, "/ws")


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 10000))
    print(f"Starting server on port {port}")
    print("WebSocket endpoint: /ws")
    uvicorn.run(app, host="0.0.0.0", port=port, ws="auto")
