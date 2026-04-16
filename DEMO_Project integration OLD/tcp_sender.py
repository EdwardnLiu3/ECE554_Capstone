"""
TCP Sender for AUP-ZU3 FPGA Board
------------------------------------
Uses a standard Python socket — no Scapy, no raw sockets, no admin rights.
The FPGA now handles the full TCP handshake (SYN → SYN-ACK → ACK), so a
normal socket.connect() works directly.

Requirements
------------
  Python 3.x  (no extra packages needed)

Usage
-----
    py tcp_sender.py
    py tcp_sender.py --fpga-ip 192.168.1.100 --port 7000 --msg "HELLO_FPGA"
    py tcp_sender.py --count 5 --delay 1.0

Setup
-----
  1. Assign your PC's Ethernet adapter a static IP in the same subnet, e.g.
       IP: 192.168.1.10   Mask: 255.255.255.0
  2. Set --fpga-ip to match MY_IP in the Verilog  (default: 192.168.1.100)
  3. Set --port to match MY_PORT in the Verilog   (default: 7000)
"""

import socket
import argparse
import time
import sys

DEFAULT_FPGA_IP  = "192.168.1.100"
DEFAULT_PORT     = 7000
DEFAULT_MSG      = "HELLO_FPGA"
TIMEOUT_SEC      = 5


def send_tcp(fpga_ip: str, port: int, message: str) -> None:
    payload = message.encode("utf-8")
    print(f"[INFO] Connecting to {fpga_ip}:{port} ...")

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(TIMEOUT_SEC)
        try:
            s.connect((fpga_ip, port))
        except ConnectionRefusedError:
            print("[ERROR] Connection refused — is the FPGA running and listening?")
            sys.exit(1)
        except socket.timeout:
            print(f"[ERROR] Timed out after {TIMEOUT_SEC}s — check IP/cable/FPGA design.")
            sys.exit(1)

        print(f"[OK]   TCP handshake complete (FPGA responded with SYN-ACK).")
        print(f"[INFO] Sending {len(payload)} bytes: {repr(message)}")
        s.sendall(payload)
        print("[OK]   Data sent — check LEDs on the FPGA board.")

        # Optional: wait briefly for any echo from the FPGA
        try:
            resp = s.recv(1024)
            if resp:
                print(f"[FPGA] Response: {resp.decode('utf-8', errors='replace')!r}")
        except socket.timeout:
            pass  # No echo expected from this design


def send_burst(fpga_ip: str, port: int, message: str, count: int, delay: float) -> None:
    for i in range(1, count + 1):
        print(f"\n── Packet {i}/{count} ──")
        send_tcp(fpga_ip, port, f"{message}:{i}")
        if i < count:
            time.sleep(delay)


def parse_args():
    p = argparse.ArgumentParser(
        description="Send TCP data to AUP-ZU3 FPGA (standard socket, no Scapy)."
    )
    p.add_argument("--fpga-ip", default=DEFAULT_FPGA_IP,
                   help=f"FPGA IP address      (default: {DEFAULT_FPGA_IP})")
    p.add_argument("--port",    type=int, default=DEFAULT_PORT,
                   help=f"TCP destination port (default: {DEFAULT_PORT})")
    p.add_argument("--msg",     default=DEFAULT_MSG,
                   help=f"Payload string       (default: {DEFAULT_MSG!r})")
    p.add_argument("--count",   type=int, default=1,
                   help="Number of packets    (default: 1)")
    p.add_argument("--delay",   type=float, default=1.0,
                   help="Seconds between burst packets (default: 1.0)")
    return p.parse_args()


if __name__ == "__main__":
    args = parse_args()
    if args.count == 1:
        send_tcp(args.fpga_ip, args.port, args.msg)
    else:
        send_burst(args.fpga_ip, args.port, args.msg, args.count, args.delay)
