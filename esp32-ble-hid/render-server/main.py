"""
Sotos Controller — WebSocket relay server for ESP32 BLE HID.

Endpoints:
  GET  /          — basic service info
  GET  /health    — liveness check
  GET  /status    — check if device is connected
  POST /command   — {"command": "TYPE Hello", "device": "sotos-james"}
  POST /commands  — {"commands": ["TYPE Hi", "ENTER"], "device": "sotos-james"}
  POST /unlock    — {"passcode": "123456", "device": "sotos-james"}
  WS   /ws        — ESP32 device channel
"""

import asyncio
import os
from datetime import datetime, timezone

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request
from fastapi.responses import JSONResponse

app = FastAPI(title="Sotos Controller")

# Connected device state — keyed by device name (e.g. "sotos-james")
device_ws: dict[str, WebSocket] = {}
pending_responses: dict[str, asyncio.Queue] = {}
# Map internal ws id → device name (for cleanup on disconnect)
ws_id_to_name: dict[int, str] = {}


def resolve_device(payload: dict):
    """Find the target device by name, or fall back to the first connected device."""
    if not device_ws:
        return None, None, None

    target = payload.get("device", "").strip()
    if target and target in device_ws:
        return target, device_ws[target], pending_responses[target]
    if target:
        # Partial match (e.g. "james" matches "sotos-james")
        for name in device_ws:
            if target in name:
                return name, device_ws[name], pending_responses[name]
        return None, None, None

    # No device specified — use first
    name = list(device_ws.keys())[0]
    return name, device_ws[name], pending_responses[name]


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

    device_name, ws, queue = resolve_device(payload)
    if not ws:
        target = payload.get("device", "")
        return JSONResponse(
            {"error": f"device '{target}' not found" if target else "no device connected",
             "available": list(device_ws.keys())},
            status_code=503,
        )

    # Drain stale responses
    while not queue.empty():
        try:
            queue.get_nowait()
        except asyncio.QueueEmpty:
            break

    try:
        await ws.send_json({"type": "command", "command": cmd})
        response = await asyncio.wait_for(queue.get(), timeout=15.0)
        return {"ok": True, "device": device_name, "command": cmd, "response": response}
    except asyncio.TimeoutError:
        return {"ok": True, "device": device_name, "command": cmd, "response": "sent (timeout)"}
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=500)


@app.post("/commands")
async def send_commands(payload: dict):
    cmds = payload.get("commands", [])
    delay = payload.get("delay", 0.3)
    if not cmds:
        return JSONResponse({"error": "missing 'commands'"}, status_code=400)

    device_name, ws, queue = resolve_device(payload)
    if not ws:
        target = payload.get("device", "")
        return JSONResponse(
            {"error": f"device '{target}' not found" if target else "no device connected",
             "available": list(device_ws.keys())},
            status_code=503,
        )

    results = []
    for cmd in cmds:
        while not queue.empty():
            try:
                queue.get_nowait()
            except asyncio.QueueEmpty:
                break
        try:
            await ws.send_json({"type": "command", "command": cmd})
            response = await asyncio.wait_for(queue.get(), timeout=15.0)
            results.append({"command": cmd, "response": response})
        except asyncio.TimeoutError:
            results.append({"command": cmd, "response": "timeout"})
        except Exception as e:
            results.append({"command": cmd, "error": str(e)})
            break
        await asyncio.sleep(delay)

    return {"ok": True, "device": device_name, "results": results}


@app.post("/unlock")
async def unlock(payload: dict):
    passcode = payload.get("passcode", "").strip() or os.environ.get(
        "IPHONE_PASSCODE", ""
    )
    if not passcode:
        return JSONResponse(
            {
                "error": "missing 'passcode' (set IPHONE_PASSCODE env var or pass in body)"
            },
            status_code=400,
        )

    device_name, ws, queue = resolve_device(payload)
    if not ws:
        target = payload.get("device", "")
        return JSONResponse(
            {"error": f"device '{target}' not found" if target else "no device connected",
             "available": list(device_ws.keys())},
            status_code=503,
        )

    steps = [("ENTER", 0), ("ENTER", 0), (f"TYPE {passcode}", 0), ("ENTER", 0.0)]

    results = []
    for idx, (cmd, delay) in enumerate(steps):
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
        if delay > 0:
            await asyncio.sleep(delay)

    return {"ok": True, "device": device_name, "action": "unlock", "results": results}


async def handle_device_ws(ws: WebSocket, path: str):
    """Shared WebSocket handler for ESP32 device connections."""
    await ws.accept()
    ws_key = id(ws)
    device_name = f"esp32-{ws_key}"  # temporary until register message
    ts = datetime.now(timezone.utc).isoformat()
    print(f"[{ts}] Device connected: {device_name} on {path}")

    # Store with temporary name; will be renamed on register
    device_ws[device_name] = ws
    pending_responses[device_name] = asyncio.Queue()
    ws_id_to_name[ws_key] = device_name

    try:
        while True:
            data = await ws.receive_json()
            msg_type = data.get("type", "")

            if msg_type == "register":
                # Rename device to its real name
                new_name = data.get("name", device_name)
                if new_name != device_name:
                    # Move entries to new name
                    device_ws[new_name] = device_ws.pop(device_name)
                    pending_responses[new_name] = pending_responses.pop(device_name)
                    ws_id_to_name[ws_key] = new_name
                    ts = datetime.now(timezone.utc).isoformat()
                    print(f"[{ts}] Device registered: {device_name} → {new_name}")
                    device_name = new_name
            elif msg_type == "heartbeat":
                await ws.send_json({"type": "heartbeat_ack"})
            elif msg_type == "response":
                await pending_responses[device_name].put(data)
            else:
                print(f"Unknown message: {data}")
    except WebSocketDisconnect:
        ts = datetime.now(timezone.utc).isoformat()
        print(f"[{ts}] Device disconnected: {device_name}")
    except Exception as e:
        ts = datetime.now(timezone.utc).isoformat()
        print(f"[{ts}] Device error: {e}")
    finally:
        device_ws.pop(device_name, None)
        pending_responses.pop(device_name, None)
        ws_id_to_name.pop(ws_key, None)


@app.websocket("/ws")
async def websocket_ws(ws: WebSocket):
    await handle_device_ws(ws, "/ws")


if __name__ == "__main__":
    import uvicorn

    port = int(os.environ.get("PORT", 10000))
    print(f"Starting server on port {port}")
    print("WebSocket endpoint: /ws")
    uvicorn.run(app, host="0.0.0.0", port=port, ws="auto")
