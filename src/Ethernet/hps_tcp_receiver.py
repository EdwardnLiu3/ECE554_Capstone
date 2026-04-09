#!/usr/bin/env python3
import socket
import struct
import os
import mmap

# Physical address of the Lightweight HPS-to-FPGA bridge
LWHPS2FPGA_BRIDGE_BASE = 0xFF200000
# Offset of our PIO component in Qsys
PIO_OFFSET = 0x0000

print("DE1-SoC TCP to FPGA Bridge")
print("Opening /dev/mem to access FPGA PIO...")
FPGA_ENABLED = False
mem = None
f = None
try:
    f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    mem = mmap.mmap(f, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=LWHPS2FPGA_BRIDGE_BASE)
    FPGA_ENABLED = True
    print("FPGA bridge opened successfully.")
except Exception as e:
    print("WARNING: Could not open FPGA bridge: {}".format(e))
    print("Running in TCP-only mode (no FPGA output).")

# Setup TCP Server
HOST = '0.0.0.0'
PORT = 7000

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((HOST, PORT))
s.listen(1)

print("Listening for TCP packets from Laptop on port {}...".format(PORT))

pkt_count = 0
if FPGA_ENABLED:
    mem.seek(PIO_OFFSET)
    mem.write(struct.pack('<I', pkt_count)) # Initialize FPGA to 0

try:
    while True:
        conn, addr = s.accept()
        print("Connected by {}".format(addr))
        while True:
            data = conn.recv(1024)
            if not data:
                break
            print("Received payload: {}".format(data.decode('utf-8', 'ignore').strip()))

            # Increment packet count and push to FPGA's PIO over the AXI bridge!
            pkt_count = (pkt_count + 1) % 100 # Loop from 0 to 99 for our 2 hex digits
            print("Packet count: {}".format(pkt_count))
            if FPGA_ENABLED:
                mem.seek(PIO_OFFSET)
                mem.write(struct.pack('<I', pkt_count))

            # Send standard TCP Ack back to the laptop
            conn.sendall(b"Packet accepted by HPS and routed to FPGA.\n")

        conn.close()
        print("Client disconnected. Waiting for new connection...")
except KeyboardInterrupt:
    print("\nShutting down.")
finally:
    if mem:
        mem.close()
    if f:
        os.close(f)
    s.close()
