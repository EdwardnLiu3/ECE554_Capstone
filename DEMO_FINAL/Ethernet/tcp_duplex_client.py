"""
Bi-Directional TCP Client for DE1-SoC FPGA
------------------------------------------
Connects to the FPGA board and keeps the connection OPEN indefinitely.
- You can type a message and press ENTER to send it to the board (updating LEDs).
- The script simultaneously listens for incoming messages originating from the
  physical push buttons on the FPGA board!

Usage
-----
    python tcp_duplex_client.py --fpga-ip 192.168.1.101 --port 7000
"""

import socket
import argparse
import sys
import threading

DEFAULT_FPGA_IP  = "192.168.1.101"
DEFAULT_PORT     = 7000

def receive_loop(sock: socket.socket):
    """Continuously listens for incoming messages from the FPGA."""
    while True:
        try:
            data = sock.recv(1024)
            if not data:
                print("\n[DISCONNECTED] FPGA closed the connection.")
                # Force exit
                import os
                os._exit(0)
                
            print(f"\n<<< [BOARD MESSAGE]: {data.decode('utf-8', errors='replace').strip()}")
            print(">>> Type message to send (or 'exit'): ", end="", flush=True)
            
        except ConnectionAbortedError:
            break
        except Exception as e:
            print(f"\n[ERROR] Connection lost: {e}")
            import os
            os._exit(0)

def main():
    p = argparse.ArgumentParser(description="Bi-Directional TCP Client for FPGA.")
    p.add_argument("--fpga-ip", default=DEFAULT_FPGA_IP, help=f"FPGA IP (default: {DEFAULT_FPGA_IP})")
    p.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"Port (default: {DEFAULT_PORT})")
    args = p.parse_args()

    print(f"[INFO] Connecting to {args.fpga_ip}:{args.port} ...")

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(5.0)
        try:
            s.connect((args.fpga_ip, args.port))
            s.settimeout(None) # Remove timeout to keep connection permanently open
        except Exception as e:
            print(f"[ERROR] Connection failed: {e}")
            sys.exit(1)

        print(f"[OK] Connected! Full Duplex channel established.")
        print("-" * 50)
        
        # Start the background listening thread
        receiver_thread = threading.Thread(target=receive_loop, args=(s,), daemon=True)
        receiver_thread.start()

        # Foreground sending loop
        while True:
            try:
                msg = input(">>> Type message to send (or 'exit'): ")
                if msg.strip().lower() == 'exit':
                    break
                if msg.strip():
                    s.sendall(msg.encode("utf-8"))
            except KeyboardInterrupt:
                break

    print("\n[INFO] Closing connection.")

if __name__ == "__main__":
    main()
