import socket
import argparse
import sys
import threading
import time
import csv
import struct
from pathlib import Path

sys.path.append(str(Path(__file__).parent / "ITCH_Translator"))
from lobster_to_itch import STOCK_ID_TO_TICKER, translate_row

DEFAULT_FPGA_IP  = "192.168.1.101"
DEFAULT_PORT     = 7000
DEFAULT_CSV      = Path(__file__).parent / "ITCH_Translator" / "LOBSTER_SampleFile_AMZN_2012-06-21_1" / "two_stock_style_hour_message_clean_merged.csv"
RAW_OUCH_PAYLOAD_BYTES = 94
TAGGED_OUCH_FRAME_BYTES = RAW_OUCH_PAYLOAD_BYTES + 2


def _is_ouch_message_type(value: int) -> bool:
    return value in (0x4F, 0x55)


def _decode_raw_ouch_slot(slot: bytes) -> str:
    if not slot:
        return "empty"
    msg_type = slot[0]
    try:
        if msg_type == 0x4F and len(slot) >= 29:
            ref_num = struct.unpack(">I", slot[1:5])[0]
            side    = chr(slot[5])
            qty     = struct.unpack(">I", slot[6:10])[0]
            symbol  = slot[10:18].decode("ascii").strip()
            price   = struct.unpack(">Q", slot[18:26])[0]
            return f"ENTER side={side} qty={qty} price=${price/100.0:.2f} symbol='{symbol}' ref={ref_num}"
        if msg_type == 0x55 and len(slot) >= 25:
            orig_ref = struct.unpack(">I", slot[1:5])[0]
            new_ref  = struct.unpack(">I", slot[5:9])[0]
            qty      = struct.unpack(">I", slot[9:13])[0]
            price    = struct.unpack(">Q", slot[13:21])[0]
            return f"REPLACE orig_ref={orig_ref} new_ref={new_ref} qty={qty} price=${price/100.0:.2f}"
    except Exception as ex:
        return f"decode error ({ex})"
    return f"unknown raw type 0x{msg_type:02X}"


def decode_raw_ouch_frame(payload: bytes, stock_id: int | None = None) -> str:
    stock_label = ""
    if stock_id is not None:
        stock_label = f"stock_id={stock_id}"
        ticker = STOCK_ID_TO_TICKER.get(stock_id)
        if ticker:
            stock_label += f" ticker='{ticker}'"
        stock_label += " "
    first = _decode_raw_ouch_slot(payload[:47])
    second = _decode_raw_ouch_slot(payload[47:94])
    return f"{stock_label}{first} | {second}"

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

        # ---- OUCH outbound messages sent back by the FPGA Order_Generator ----
        # These packets arrive as SoupBinTCP 'S' frames (data[2]='S'),
        # with data[3] = OUCH message type byte.
        elif msg_type == 'O':  # 0x4F  Enter Order
            # Byte offsets relative to data[3] (the OUCH type byte):
            # [4:8]  UserRefNum  (4-byte big-endian)
            # [8]    Side        (0x42='B', 0x53='S')
            # [9:13] Quantity    (4-byte big-endian)
            # [13:21] Symbol     (8 chars)
            # [21:29] Price      (8-byte big-endian, in cents)
            ref_num = struct.unpack(">I", data[4:8])[0]
            side    = chr(data[8])
            qty     = struct.unpack(">I", data[9:13])[0]
            symbol  = data[13:21].decode("ascii").strip()
            price   = struct.unpack(">Q", data[21:29])[0]
            return (f"[FPGA\u2192] ENTER ORDER: Side={side}, Qty={qty}, "
                    f"Price=${price/100.0:.2f}, Symbol='{symbol}', RefNum={ref_num}")

        elif msg_type == 'U':  # 0x55  Replace Order
            # [4:8]  OrigUserRefNum (4-byte big-endian)
            # [8:12] UserRefNum     (4-byte big-endian)
            # [12:16] Quantity      (4-byte big-endian)
            # [16:24] Price         (8-byte big-endian, in cents)
            orig_ref = struct.unpack(">I", data[4:8])[0]
            new_ref  = struct.unpack(">I", data[8:12])[0]
            qty      = struct.unpack(">I", data[12:16])[0]
            price    = struct.unpack(">Q", data[16:24])[0]
            return (f"[FPGA\u2192] REPLACE ORDER: OrigRefNum={orig_ref}, NewRefNum={new_ref}, "
                    f"Qty={qty}, Price=${price/100.0:.2f}")

        else:
            return f"Unknown Message Type '{msg_type}'"

    except Exception as ex:
        return f"Error decoding message type '{msg_type}': {ex}"

def receive_loop(sock: socket.socket):
    """Continuously listens for incoming binary messages from the FPGA.
    
    Handles three return formats:
      - tagged raw 96-byte OUCH payloads from tcp_receiver.c
      - legacy raw 94-byte OUCH payloads
      - older SoupBinTCP-framed echoes
    """
    buf = b""
    while True:
        try:
            chunk = sock.recv(4096)
            if not chunk:
                print("\n[DISCONNECTED] FPGA closed the connection (receive_loop).")
                import os
                os._exit(0)

            buf += chunk

            while True:
                if len(buf) >= TAGGED_OUCH_FRAME_BYTES:
                    stock_id = int.from_bytes(buf[0:2], "big")
                    if stock_id in STOCK_ID_TO_TICKER and _is_ouch_message_type(buf[2]) and _is_ouch_message_type(buf[49]):
                        payload = buf[2:TAGGED_OUCH_FRAME_BYTES]
                        buf = buf[TAGGED_OUCH_FRAME_BYTES:]
                        print(f"\n<<< [FPGA OUCH OUT] {decode_raw_ouch_frame(payload, stock_id)}")
                        continue

                if len(buf) >= 2 and int.from_bytes(buf[0:2], "big") in STOCK_ID_TO_TICKER:
                    break

                if len(buf) >= RAW_OUCH_PAYLOAD_BYTES and _is_ouch_message_type(buf[0]) and _is_ouch_message_type(buf[47]):
                    payload = buf[:RAW_OUCH_PAYLOAD_BYTES]
                    buf = buf[RAW_OUCH_PAYLOAD_BYTES:]
                    print(f"\n<<< [FPGA OUCH OUT] {decode_raw_ouch_frame(payload)}")
                    continue

                if len(buf) >= 1 and _is_ouch_message_type(buf[0]):
                    break

                if len(buf) < 2:
                    break

                msg_len = struct.unpack(">H", buf[0:2])[0]
                frame_total = msg_len + 2
                if len(buf) < frame_total:
                    break
                frame = buf[:frame_total]
                buf   = buf[frame_total:]

                readable_msg = decode_itch(frame)
                if readable_msg.startswith("[FPGA"):
                    print(f"\n<<< [FPGA OUCH OUT] {readable_msg}")
                else:
                    print(f"\n<<< [BOARD ECHO]     {readable_msg}")

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
    p.add_argument("--csv", default=DEFAULT_CSV, type=Path, help=f"Path to the LOBSTER message CSV file (default: {DEFAULT_CSV})")
    p.add_argument("--ticker", default="INTC", help="Fallback stock ticker symbol for legacy rows/payloads (default: INTC)")
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
        order_id_state = {}
        sent_count = 0
        skipped = 0
        last_timestamp = None

        print(f"[INFO] Reading CSV: {args.csv}")
        with open(args.csv, newline="") as csv_file:
            reader = csv.reader(csv_file)
            for row in reader:
                if len(row) not in (6, 7):
                    skipped += 1
                    continue
                
                # Extract timestamp to calculate delays
                ts = float(row[0])
                
                packet = translate_row(row, args.ticker, match_counter, order_id_state)
                
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
        print(f"[INFO] Skipped {skipped} rows.")
        
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
