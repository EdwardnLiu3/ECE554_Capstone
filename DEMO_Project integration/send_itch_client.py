import socket
import argparse
import sys
import threading
import time
import csv
import struct
from pathlib import Path

sys.path.append(str(Path(__file__).parent / "ITCH_Translator"))
from lobster_to_itch import translate_row

DEFAULT_FPGA_IP  = "192.168.1.101"
DEFAULT_PORT     = 7000

def decode_itch(data: bytes) -> str:
    if len(data) < 3:
        return f"Unknown or incomplete packet ({len(data)} bytes)"
    
    msg_len = struct.unpack(">H", data[0:2])[0]
    if len(data) < msg_len + 2:
        return f"Incomplete packet (expected {msg_len+2}, got {len(data)})"
    
    packet_type = chr(data[2])
    if packet_type != 'S':
        return f"Not a Sequenced packet! Type: {packet_type}"
        
    if len(data) < 14:
        return "Packet too short to contain basic ITCH headers."

    msg_type = chr(data[3])
    
    # unpack timestamp (6 bytes) by padding to 8 bytes and dividing by 1e9
    ts_ns = struct.unpack(">Q", b'\x00\x00' + data[8:14])[0]
    ts_sec = ts_ns / 1_000_000_000.0

    try:
        if msg_type == 'A':
            order_id = struct.unpack(">Q", data[14:22])[0]
            side = chr(data[22])
            shares = struct.unpack(">I", data[23:27])[0]
            stock = data[27:35].decode("ascii").strip()
            price = struct.unpack(">I", data[35:39])[0]
            return f"ADD ORDER: Ticker='{stock}', Side={side}, Shares={shares}, Price={price/10000.0:.4f}, OrderID={order_id}, Time={ts_sec:.6f}"

        elif msg_type == 'X':
            order_id = struct.unpack(">Q", data[14:22])[0]
            cancelled = struct.unpack(">I", data[22:26])[0]
            return f"ORDER CANCEL: OrderID={order_id}, CancelledShares={cancelled}, Time={ts_sec:.6f}"

        elif msg_type == 'D':
            order_id = struct.unpack(">Q", data[14:22])[0]
            return f"ORDER DELETE: OrderID={order_id}, Time={ts_sec:.6f}"

        elif msg_type == 'E':
            order_id = struct.unpack(">Q", data[14:22])[0]
            executed = struct.unpack(">I", data[22:26])[0]
            match_num = struct.unpack(">Q", data[26:34])[0]
            return f"ORDER EXECUTED: OrderID={order_id}, ExecutedShares={executed}, MatchNum={match_num}, Time={ts_sec:.6f}"

        elif msg_type == 'P':
            order_id = struct.unpack(">Q", data[14:22])[0]
            side = chr(data[22])
            shares = struct.unpack(">I", data[23:27])[0]
            stock = data[27:35].decode("ascii").strip()
            price = struct.unpack(">I", data[35:39])[0]
            match_num = struct.unpack(">Q", data[39:47])[0]
            return f"TRADE (HIDDEN): Ticker='{stock}', Side={side}, Shares={shares}, Price={price/10000.0:.4f}, MatchNum={match_num}, Time={ts_sec:.6f}"

        elif msg_type == 'H':
            stock = data[14:22].decode("ascii").strip()
            status = chr(data[22])
            return f"TRADING ACTION: Ticker='{stock}', Status={status}, Time={ts_sec:.6f}"

        else:
            return f"Unknown Message Type '{msg_type}'"

    except Exception as ex:
        return f"Error decoding message type '{msg_type}': {ex}"

def receive_loop(sock: socket.socket):
    """Continuously listens for incoming binary messages from the FPGA."""
    while True:
        try:
            data = sock.recv(1024)
            if not data:
                print("\n[DISCONNECTED] FPGA closed the connection (receive_loop).")
                import os
                os._exit(0)
                
            readable_msg = decode_itch(data)
            print(f"\n<<< [BOARD MESSAGE ECHO] {readable_msg}")
            
        except ConnectionAbortedError:
            break
        except Exception as e:
            print(f"\n[ERROR] Connection lost: {e}")
            import os
            os._exit(0)

def main():
    p = argparse.ArgumentParser(description="Bi-Directional TCP Client for streaming ITCH Orders to FPGA.")
    p.add_argument("--fpga-ip", default=DEFAULT_FPGA_IP, help=f"FPGA IP (default: {DEFAULT_FPGA_IP})")
    p.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"Port (default: {DEFAULT_PORT})")
    p.add_argument("--csv", required=True, type=Path, help="Path to the LOBSTER message CSV file")
    p.add_argument("--ticker", default="AMZN", help="Stock ticker symbol (default: AMZN)")
    p.add_argument("--orders", type=int, default=10, help="Number of orders to send (default: 10). Use -1 for all.")
    p.add_argument("--speed", type=float, default=1.0, help="Speed multiplier for timestamp delays (e.g., 2.0 = twice as fast). default: 1.0")
    
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

        # Foreground sending LOBSTER loop
        match_counter = [0]
        order_id_map  = {}
        sent_count = 0
        skipped = 0
        last_timestamp = None

        print(f"[INFO] Reading CSV: {args.csv}")
        with open(args.csv, newline="") as csv_file:
            reader = csv.reader(csv_file)
            for row in reader:
                if len(row) != 6:
                    skipped += 1
                    continue
                
                # Extract timestamp to calculate delays
                ts = float(row[0])
                
                packet = translate_row(row, args.ticker, match_counter, order_id_map)
                
                if packet is None:
                    skipped += 1
                    continue
                
                # Perform delay calculation
                if last_timestamp is not None:
                    delay = ts - last_timestamp
                    if delay > 0:
                        scaled_delay = delay / args.speed
                        time.sleep(scaled_delay)
                last_timestamp = ts
                
                # Send the binary packet
                try:
                    s.sendall(packet)
                    sent_count += 1
                    print(f"[SENT {sent_count}] Type: {row[1]}, Size: {len(packet)} bytes")
                except Exception as e:
                    print(f"\n[ERROR] Failed to send data: {e}")
                    break

                if args.orders != -1 and sent_count >= args.orders:
                    break

        print(f"\n[INFO] Finished sending {sent_count} orders over TCP.")
        print(f"[INFO] Unique order IDs mapped: {len(order_id_map)}. Skipped {skipped} rows.")
        
        print("\n[INFO] Stream complete. Still listening for echoed packets from FPGA...")
        try:
           # Keep main thread alive so background receiver continues listening
           while True:
               time.sleep(1)
        except KeyboardInterrupt:
           pass

    print("\n[INFO] Closing connection.")

if __name__ == "__main__":
    main()
