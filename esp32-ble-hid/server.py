"""
Sotos Controller — Modal Sandbox launcher.

Usage:
  python server.py           # Start or reconnect to sandbox
  python server.py --stop    # Stop the sandbox
  python server.py --status  # Check sandbox status

The sandbox runs a FastAPI server with both HTTP API and WebSocket.
ESP32 connects via plain WebSocket (no SSL) through an unencrypted tunnel.
External clients send commands via the same HTTP endpoint.
Sandbox lifetime is capped at 24h by Modal.
"""

import modal
import sys

APP_NAME = "sotos-controller"
SANDBOX_NAME = "sotos-ws-2"
INTERNAL_PORT = 10000

app = modal.App.lookup(APP_NAME, create_if_missing=True)

image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install("fastapi[standard]", "uvicorn[standard]", "websockets")
    .add_local_file("render-server/main.py", "/app/main.py")
)


def get_existing_sandbox():
    """Try to find a running sandbox by name."""
    try:
        sb = modal.Sandbox.from_name(APP_NAME, SANDBOX_NAME)
        return sb
    except Exception:
        return None


def print_tunnel_info(sb):
    """Print the tunnel addresses for a running sandbox."""
    tunnels = sb.tunnels()
    if not tunnels:
        print("No tunnels found (sandbox may still be starting).")
        return None

    for port, tunnel in tunnels.items():
        host, tport = tunnel.tcp_socket
        print(f"\n{'='*50}")
        print(f"  ESP32 WebSocket:  ws://{host}:{tport}/ws")
        print(f"  HTTP API:         http://{host}:{tport}")
        print(f"  Health:           http://{host}:{tport}/health")
        print(f"  Status:           http://{host}:{tport}/status")
        print(f"{'='*50}")
        return f"{host}:{tport}"
    return None


def create_sandbox():
    """Create a new sandbox with the WebSocket server."""
    print("Creating sandbox...")

    with modal.enable_output():
        sb = modal.Sandbox.create(
            "python", "/app/main.py",
            image=image,
            app=app,
            unencrypted_ports=[INTERNAL_PORT],
            timeout=86400,       # 24 hours max
            name=SANDBOX_NAME,
        )

    print(f"Sandbox created: {sb.object_id}")
    return sb


if __name__ == "__main__":
    if "--stop" in sys.argv:
        sb = get_existing_sandbox()
        if sb:
            sb.terminate()
            print("Sandbox terminated.")
        else:
            print("No running sandbox found.")
        sys.exit(0)

    if "--status" in sys.argv:
        sb = get_existing_sandbox()
        if sb:
            print(f"Sandbox running: {sb.object_id}")
            print_tunnel_info(sb)
        else:
            print("No running sandbox found.")
        sys.exit(0)

    # Start or reconnect
    sb = get_existing_sandbox()
    if sb:
        print(f"Reconnecting to existing sandbox: {sb.object_id}")
    else:
        sb = create_sandbox()

    import time
    # Wait a moment for the server to start
    time.sleep(3)

    addr = print_tunnel_info(sb)

    print(f"\nSandbox ID: {sb.object_id}")
    print("Press Ctrl+C to detach (sandbox keeps running).\n")

    try:
        for line in sb.stdout:
            print(line, end="")
    except KeyboardInterrupt:
        print("\nDetached. Sandbox still running.")
        if addr:
            print(f"Reconnect: python server.py")
            print(f"Stop:      python server.py --stop")
