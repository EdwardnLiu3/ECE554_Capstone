#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/mman.h>
#include <stdbool.h>
#include <string.h>
#include <ctype.h>
#include <stdint.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <errno.h>

// HW definitions
#define HW_REGS_BASE ( 0xFC000000 ) // ALT_STM_OFST
#define HW_REGS_SPAN ( 0x04000000 )
#define HW_REGS_MASK ( HW_REGS_SPAN - 1 )

#define ALT_LWFPGASLVS_OFST ( 0xFF200000 )
#define LED_PIO_BASE ( 0x10040 )
#define SEG7_IF_BASE ( 0x10020 )
#define BUTTON_PIO_BASE ( 0x10080 )

volatile unsigned long *h2p_lw_led_addr=NULL;
volatile unsigned long *h2p_lw_hex_addr=NULL;
volatile unsigned long *h2p_lw_button_addr=NULL;
volatile unsigned long *h2p_lw_parser_addr=NULL;

#define TCP_RECEIVER_BUILD_ID "two-stock-debug-2026-04-27"
#define FORCE_AUTO_STREAM 1

// 7-segment hex decoding
static unsigned char szMap[] = {
    63, 6, 91, 79, 102, 109, 125, 7, 
    127, 111, 119, 124, 57, 94, 121, 113
};

void SEG7_Decimal(unsigned long Data) {
    int i;
    unsigned char seg_mask;
    for(i=0; i<6; i++){
        seg_mask = szMap[Data % 10];
        Data /= 10;
        *(h2p_lw_hex_addr + i) = seg_mask;
    }          
}

// Show two values split across the display:
// hi3 -> HEX5-HEX3 (outbound OUCH order count)
// lo3 -> HEX2-HEX0 (last incoming packet byte count)
void SEG7_Split(unsigned long hi3, unsigned long lo3) {
    int i;
    unsigned char seg_mask;
    unsigned long lv = lo3;
    unsigned long hv = hi3;
    for(i=0; i<3; i++){
        seg_mask = szMap[lv % 10];
        lv /= 10;
        *(h2p_lw_hex_addr + i) = seg_mask;   // HEX0, HEX1, HEX2
    }
    for(i=3; i<6; i++){
        seg_mask = szMap[hv % 10];
        hv /= 10;
        *(h2p_lw_hex_addr + i) = seg_mask;   // HEX3, HEX4, HEX5
    }
}

void LED_Set(unsigned long Data) {
    *h2p_lw_led_addr = Data & 0x3FF; 
}

unsigned long Parser_Debug_Read(unsigned int select) {
    *(h2p_lw_parser_addr + 63) = select & 0x3F;
    return *(h2p_lw_parser_addr + 63);
}

long long Parser_Read_Signed64(unsigned int lo_reg, unsigned int hi_reg) {
    uint32_t lo = (uint32_t)*(h2p_lw_parser_addr + lo_reg);
    uint32_t hi = (uint32_t)*(h2p_lw_parser_addr + hi_reg);
    uint64_t combined = ((uint64_t)hi << 32) | lo;
    return (long long)(int64_t)combined;
}

static uint16_t read_be16(const unsigned char *buf) {
    return ((uint16_t)buf[0] << 8) | (uint16_t)buf[1];
}

static uint32_t read_be32(const unsigned char *buf) {
    return ((uint32_t)buf[0] << 24) |
           ((uint32_t)buf[1] << 16) |
           ((uint32_t)buf[2] << 8)  |
           (uint32_t)buf[3];
}

static uint64_t read_be64(const unsigned char *buf) {
    uint64_t value = 0;
    int i;
    for (i = 0; i < 8; i++) {
        value = (value << 8) | buf[i];
    }
    return value;
}

static void Print_ITCH_Summary(const unsigned char *payload, int payload_len) {
    if (payload_len < 1) {
        printf("[RX->FPGA] empty payload\n");
        return;
    }

    printf("[RX->FPGA] ITCH type '%c' (0x%02X), payload_len=%d\n",
           isprint(payload[0]) ? payload[0] : '?', payload[0], payload_len);

    if (payload_len >= 11) {
        uint16_t stock_locate = read_be16(payload + 1);
        uint64_t ts_ns = 0;
        int i;
        for (i = 5; i < 11; i++) {
            ts_ns = (ts_ns << 8) | payload[i];
        }
        printf("           stock_locate=%u timestamp_ns=%llu\n",
               stock_locate, (unsigned long long)ts_ns);
    }

    switch (payload[0]) {
        case 'A':
            if (payload_len >= 36) {
                printf("           order_id=%llu side=%c qty=%lu price=%lu\n",
                       (unsigned long long)read_be64(payload + 11),
                       payload[19],
                       (unsigned long)read_be32(payload + 20),
                       (unsigned long)read_be32(payload + 32));
            }
            break;
        case 'X':
            if (payload_len >= 23) {
                printf("           cancel order_id=%llu qty=%lu\n",
                       (unsigned long long)read_be64(payload + 11),
                       (unsigned long)read_be32(payload + 19));
            }
            break;
        case 'D':
            if (payload_len >= 19) {
                printf("           delete order_id=%llu\n",
                       (unsigned long long)read_be64(payload + 11));
            }
            break;
        case 'E':
            if (payload_len >= 31) {
                printf("           execute order_id=%llu qty=%lu\n",
                       (unsigned long long)read_be64(payload + 11),
                       (unsigned long)read_be32(payload + 19));
            }
            break;
        default:
            printf("           unsupported-by-parser type, packet will be ignored by FPGA parser\n");
            break;
    }
}

// Read the latched 752-bit OUCH payload from Avalon regs 32-55,
// reconstruct big-endian byte order, prefix it with the 16-bit stock_id that
// generated it, and send the tagged 96-byte frame back to the laptop.
static void Send_OUCH_Payload(int sock, unsigned long count, uint16_t stock_id) {
    uint32_t words[24];
    int i;
    for(i = 0; i < 24; i++)
        words[i] = (uint32_t)*(h2p_lw_parser_addr + 32 + i);

    /* Avalon mapping:
     *   addr 32 -> payload[31:0]  (LSB word)
     *   addr 33 -> payload[63:32]
     *   ...
     *   addr 55 -> {16'd0, payload[751:736]}  (MSB word, upper 16 bits only)
     *
     * OUCH byte 0 = payload[751:744] = words[23] bits [15:8]
     * OUCH byte 1 = payload[743:736] = words[23] bits [7:0]
     * OUCH bytes 2-5 = words[22] big-endian, etc.
     */
    uint8_t ouch[94];
    ouch[0] = (words[23] >> 8) & 0xFF;
    ouch[1] =  words[23]       & 0xFF;
    for(i = 22; i >= 0; i--) {
        int base = 2 + (22 - i) * 4;
        ouch[base + 0] = (words[i] >> 24) & 0xFF;
        ouch[base + 1] = (words[i] >> 16) & 0xFF;
        ouch[base + 2] = (words[i] >>  8) & 0xFF;
        ouch[base + 3] =  words[i]         & 0xFF;
    }

    {
        uint8_t tagged_ouch[96];
        tagged_ouch[0] = (stock_id >> 8) & 0xFF;
        tagged_ouch[1] = stock_id & 0xFF;
        memcpy(&tagged_ouch[2], ouch, sizeof(ouch));
        send(sock, tagged_ouch, sizeof(tagged_ouch), 0);
    }

    printf("[OUCH OUT #%lu] sent 96-byte tagged payload for stock_id=%u (order 0 type=0x%02X, order 1 type=0x%02X)\n",
           count, stock_id, ouch[0], ouch[47]);
}

int extract_last_integer(const char* str) {
    int last_val = -1;
    long current_val = 0;
    int has_digit = 0;
    
    for (int i = 0; str[i] != '\0'; i++) {
        if (isdigit(str[i])) {
            current_val = (current_val * 10) + (str[i] - '0');
            has_digit = 1;
        } else {
            if (has_digit) {
                last_val = current_val;
                current_val = 0;
                has_digit = 0;
            }
        }
    }
    if (has_digit) last_val = current_val;
    return last_val;
}

int main(int argc, char **argv) {
    void *virtual_base;
    int fd;

    printf("--- TCP HPS-to-FPGA Receiver & Sender (C) ---\n");
    printf("[BUILD] %s\n", TCP_RECEIVER_BUILD_ID);

    if( ( fd = open( "/dev/mem", ( O_RDWR | O_SYNC ) ) ) == -1 ) {
        printf( "ERROR: could not open \"/dev/mem\"...\n" );
        return( 1 );
    }

    virtual_base = mmap( NULL, HW_REGS_SPAN, ( PROT_READ | PROT_WRITE ), MAP_SHARED, fd, HW_REGS_BASE );    
    if( virtual_base == MAP_FAILED ) {
        printf( "ERROR: mmap() failed...\n" );
        close( fd );
        return( 1 );
    }

    h2p_lw_led_addr = virtual_base + ( ( unsigned long )( ALT_LWFPGASLVS_OFST + LED_PIO_BASE ) & ( unsigned long)( HW_REGS_MASK ) );
    h2p_lw_hex_addr = virtual_base + ( ( unsigned long )( ALT_LWFPGASLVS_OFST + SEG7_IF_BASE ) & ( unsigned long)( HW_REGS_MASK ) );
    h2p_lw_button_addr = virtual_base + ( ( unsigned long )( ALT_LWFPGASLVS_OFST + BUTTON_PIO_BASE ) & ( unsigned long)( HW_REGS_MASK ) );
    h2p_lw_parser_addr = virtual_base + ( ( unsigned long )( ALT_LWFPGASLVS_OFST + 0x10100 ) & ( unsigned long)( HW_REGS_MASK ) );

    LED_Set(0);
    SEG7_Decimal(0);

    printf("[INFO] Parser wrapper base offset: 0x10100\n");
    printf("[INFO] FPGA base-price probe (debug_select=0): %lu\n", Parser_Debug_Read(0));
    printf("[INFO] Auto stream mode: %s\n", FORCE_AUTO_STREAM ? "FORCED ON in software" : "controlled by SW0");

    int server_fd, new_socket;
    struct sockaddr_in address;
    int opt = 1;
    int addrlen = sizeof(address);

    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        exit(EXIT_FAILURE);
    }
    
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt))) {
        perror("setsockopt");
        exit(EXIT_FAILURE);
    }

    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons( 7000 );

    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("bind failed");
        exit(EXIT_FAILURE);
    }
    
    if (listen(server_fd, 3) < 0) {
        perror("listen");
        exit(EXIT_FAILURE);
    }

    printf("[INFO] Hardware initialized. Listening on port 7000...\n");

    while (1) {
        printf("[INFO] Waiting for connection from laptop...\n");
        if ((new_socket = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen)) < 0) {
            perror("accept");
            continue;
        }
        
        printf("[INFO] Client connected!\n");

        // Reset parser and orderbook state for the new session
        *(h2p_lw_parser_addr + 22) = 1;  // pulse soft_rst_n low for 1 cycle
        printf("[INFO] Hardware state reset for new session.\n");

        // Set socket to non-blocking so we can read from it while also polling buttons
        int flags = fcntl(new_socket, F_GETFL, 0);
        fcntl(new_socket, F_SETFL, flags | O_NONBLOCK);

        unsigned long last_button_state = 0xF; // 4 buttons, active low (unpressed = 1)

        // New cached packet buffer
        unsigned char cached_packet[65536] = {0};
        int cached_packet_len = 0;
        int cached_packet_ptr = 0;

        // Seed from the live hardware counter so we do not replay payloads
        // that were generated during a previous client session.
        unsigned long last_seen_order_count = *(h2p_lw_parser_addr + 58);
        unsigned long last_rx_bytes = 0;
        printf("[INFO] Seeding OUCH order count from hardware: %lu\n", last_seen_order_count);

        while (1) {
            // 1. Check for incoming network data
            unsigned char temp_buffer[8192];
            memset(temp_buffer, 0, sizeof(temp_buffer));
            int valread = read(new_socket, temp_buffer, sizeof(temp_buffer));
            if (valread > 0) {
                printf("\n[RECEIVED] %d bytes of binary data added to cache.\n", valread);
                // Save it to cache
                if (cached_packet_ptr >= cached_packet_len) {
                     // Reset cache if we've sent everything
                     cached_packet_len = 0;
                     cached_packet_ptr = 0;
                }
                
                if (cached_packet_len + valread < sizeof(cached_packet)) {
                     memcpy(cached_packet + cached_packet_len, temp_buffer, valread);
                     cached_packet_len += valread;
                }
                
                // Display: upper HEX digits = OUCH count, lower = rx bytes
                last_rx_bytes = valread;
                SEG7_Split(last_seen_order_count, last_rx_bytes);
                LED_Set(valread);
            } else if (valread == 0) {
                printf("[INFO] Client disconnected.\n");
                break;
            } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
                perror("[ERROR] socket read");
                break;
            }

            // 2. Poll FPGA keys / mode switch.
            // button_pio exports {SW[0], KEY[2:0]} in this design:
            //   bit[3] = SW0  (stream mode switch, not active-low)
            //   bit[2:0] = KEY2..KEY0 (active-low push buttons)
            unsigned long current_button_state = *h2p_lw_button_addr & 0xF;
            int auto_mode = FORCE_AUTO_STREAM ? 1 : ((current_button_state & 0x08) ? 1 : 0);
            int packets_to_process = 0;
            int triggered_by = -1;

            if (auto_mode) {
                packets_to_process = 999999; // Drain cache
            } else {
                // Edge detection (only trigger once per press for manual mode)
                if ((current_button_state & 0x7) != (last_button_state & 0x7)) {
                    for (int i=0; i<3; i++) {
                        // Active low: Went from 1 (unpressed) to 0 (pressed)
                        if (((last_button_state >> i) & 1) && !((current_button_state >> i) & 1)) {
                            packets_to_process = 1;
                            triggered_by = i;
                        }
                    }
                }
            }
            last_button_state = current_button_state;

            while (packets_to_process > 0) {
                if (cached_packet_ptr < cached_packet_len) {
                    if (triggered_by != -1) {
                        printf("\n======================================================\n");
                        printf("[EVENT] FPGA KEY%d Pressed! Feeding packet to HW PARSER...\n", triggered_by);
                        triggered_by = -1; // Only print once per press
                    } else if (!auto_mode) {
                        // No print needed
                    }
                    
                    // Extract SoupBinTCP 2-byte length
                    int msg_len = (cached_packet[cached_packet_ptr] << 8) | cached_packet[cached_packet_ptr+1];
                    int total_len = msg_len + 2;
                    
                    // Bounds check
                    if (cached_packet_ptr + total_len <= cached_packet_len) {
                                // Strip the 3-byte SoupBinTCP framing
                                if (msg_len >= 1) {
                                    int payload_len = msg_len - 1; // subtract 'S' byte
                                    unsigned char* payload = &cached_packet[cached_packet_ptr + 3];
                                    unsigned char packet_type = cached_packet[cached_packet_ptr + 2];

                                    printf("[CACHE] framed_len=%d packet_type='%c' payload_type='%c'\n",
                                           total_len,
                                           isprint(packet_type) ? packet_type : '?',
                                           (payload_len > 0 && isprint(payload[0])) ? payload[0] : '?');
                                    if (packet_type != 'S') {
                                        printf("[WARN] Packet type is 0x%02X, expected SoupBinTCP 'S'\n", packet_type);
                                    }
                                    Print_ITCH_Summary(payload, payload_len);

                                    // 1. Clear previous payload in memory
                                    for(int w=0; w<9; w++) {
                                        *(h2p_lw_parser_addr + w) = 0;
                                    }
                                    
                                    // 2. Load bytes into 32-bit Avalon words mapping to i_payload
                                    unsigned long words[9] = {0};
                                    for(int b=0; b < payload_len && b < 36; b++) {
                                        int word_idx = b / 4;
                                        int byte_shift = (b % 4) * 8;
                                        words[word_idx] |= ((unsigned long)payload[b]) << byte_shift;
                                    }
                                    
                                    for(int w=0; w<9; w++) {
                                        *(h2p_lw_parser_addr + w) = words[w];
                                    }
                                    
                                    // 3. Strobe Valid signal (address 9)
                                    *(h2p_lw_parser_addr + 9) = 1;
                                    
                                    // Give FPGA pipeline time to finish (8+ clock cycles)
                                    usleep(1);
                                    
                                    // 4. Read latched parser debug outputs. These are exposed through
                                    // debug selector register 63 so software does not miss 1-cycle pulses.
                                    unsigned long out_order_id_lo = Parser_Debug_Read(1);
                                    unsigned long out_order_id_hi = Parser_Debug_Read(2);
                                    unsigned long out_qty         = Parser_Debug_Read(3);
                                    unsigned long out_price       = Parser_Debug_Read(4);
                                    unsigned long out_flags       = Parser_Debug_Read(5);
                                    unsigned long out_ts_lo       = Parser_Debug_Read(7);
                                    unsigned long out_ts_hi       = Parser_Debug_Read(8);

                                    unsigned long long out_order_id =
                                        ((unsigned long long)out_order_id_hi << 32) | out_order_id_lo;
                                    unsigned long long timestamp_ns =
                                        ((unsigned long long)(out_ts_hi & 0xFFFF) << 32) | out_ts_lo;

                                    // Read live orderbook/trading outputs from the real wrapper map.
                                    unsigned long ob_bid_price   = *(h2p_lw_parser_addr + 17);
                                    unsigned long ob_ask_price   = *(h2p_lw_parser_addr + 18);
                                    unsigned long ob_status      = *(h2p_lw_parser_addr + 19);
                                    unsigned long trading_bid    = *(h2p_lw_parser_addr + 20);
                                    unsigned long trading_ask    = *(h2p_lw_parser_addr + 21);
                                    unsigned long mark_price     = *(h2p_lw_parser_addr + 22);
                                    int32_t position             = (int32_t)(uint32_t)*(h2p_lw_parser_addr + 23);
                                    long long day_pnl            = Parser_Read_Signed64(24, 25);
                                    long long mtm_total_pnl      = Parser_Read_Signed64(26, 27);
                                    long long inventory_value    = Parser_Read_Signed64(28, 29);
                                    unsigned long live_qty_packed = *(h2p_lw_parser_addr + 30);
                                    unsigned long order_payload_count = *(h2p_lw_parser_addr + 58);
                                    unsigned long exec_count          = *(h2p_lw_parser_addr + 59);
                                    unsigned long bid_reject_count    = *(h2p_lw_parser_addr + 60);
                                    unsigned long ask_reject_count    = *(h2p_lw_parser_addr + 61);
                                    unsigned long ob_bid_quant   = Parser_Debug_Read(16);
                                    unsigned long ob_ask_quant   = Parser_Debug_Read(17);
                                    unsigned long live_bid_qty    = live_qty_packed & 0xFFFF;
                                    unsigned long live_ask_qty    = (live_qty_packed >> 16) & 0xFFFF;

                                    int is_valid = out_flags & 1;
                                    int side     = (out_flags >> 1) & 1;
                                    int action   = (out_flags >> 2) & 3;

                                    printf("[HW PARSER OUTPUT] Valid? %s (latched)\n", is_valid ? "YES" : "NO");

                                    printf("   -> Order ID : %llu\n", out_order_id);
                                    printf("   -> Action   : ");
                                    switch(action) {
                                        case 0: printf("ADD\n"); break;
                                        case 1: printf("CANCEL\n"); break;
                                        case 2: printf("EXECUTE\n"); break;
                                        case 3: printf("DELETE\n"); break;
                                    }
                                    printf("   -> Side     : %s\n", side ? "SELL" : "BUY");
                                    printf("   -> Quantity : %lu shares\n", out_qty);
                                    printf("   -> Price    : $%.4f  (raw=%lu)\n", out_price / 10000.0, out_price);
                                    if (!is_valid && payload_len > 0 &&
                                        (payload[0] == 'A' || payload[0] == 'X' || payload[0] == 'D' || payload[0] == 'E')) {
                                        printf("[WARN] Supported ITCH type reached FPGA bridge but parser latched invalid.\n");
                                        printf("       If this persists, the most likely causes are:\n");
                                        printf("       1) stale FPGA image programmed on the board\n");
                                        printf("       2) stale tcp_receiver binary running on the HPS\n");
                                        printf("       3) parser wrapper register map mismatch on the programmed image\n");
                                    }

                                    // Print orderbook best bid/ask state
                                    int ob_bid_valid = ob_status & 1;
                                    int ob_ask_valid = (ob_status >> 1) & 1;

                                    printf("[ORDERBOOK STATE]\n");
                                    if (ob_bid_valid) {
                                        printf("   -> Best BID : price=$%.2f  qty=%lu\n", ob_bid_price / 100.0, ob_bid_quant);
                                    } else {
                                        printf("   -> Best BID : (empty)\n");
                                    }
                                    if (ob_ask_valid) {
                                        printf("   -> Best ASK : price=$%.2f  qty=%lu\n", ob_ask_price / 100.0, ob_ask_quant);
                                    } else {
                                        printf("   -> Best ASK : (empty)\n");
                                    }

                                    // ---- RAW ORDERBOOK INPUT DEBUG ----
                                    // Read what the parser actually sent into the orderbook
                                    // Give one extra cycle for signals to settle
                                    usleep(1);
                                    unsigned long ob_in_order_id = Parser_Debug_Read(9);
                                    unsigned long ob_in_price    = Parser_Debug_Read(10);
                                    unsigned long ob_in_qty      = Parser_Debug_Read(11);
                                    unsigned long ob_in_flags    = Parser_Debug_Read(12);
                                    unsigned long ob_in_action   = (ob_in_flags >> 2) & 0x3;

                                    int ob_in_valid  = ob_in_flags & 1;
                                    int ob_in_side   = (ob_in_flags >> 1) & 1;

                                    printf("[RAW OB INPUTS (what orderbook received)]\n");
                                    printf("   -> OB Order ID : %lu\n", ob_in_order_id);
                                    printf("   -> OB Action   : ");
                                    switch(ob_in_action) {
                                        case 0: printf("ADD\n"); break;
                                        case 1: printf("CANCEL\n"); break;
                                        case 2: printf("EXECUTE\n"); break;
                                        case 3: printf("DELETE\n"); break;
                                    }
                                    printf("   -> OB Side     : %s\n", ob_in_side ? "SELL" : "BUY");
                                    printf("   -> OB Quantity : %lu shares\n", ob_in_qty);
                                    printf("   -> OB Price    : $%.2f  (raw=%lu)\n", ob_in_price / 100.0, ob_in_price);
                                    printf("   -> OB Valid    : %s\n", ob_in_valid ? "YES (latched)" : "NO");
                                    // ------------------------------------

                                    // ---- ORDERBOOK PIPELINE OUTPUTS ----
                                    unsigned long ob_out_price  = Parser_Debug_Read(13);
                                    unsigned long ob_out_qty    = Parser_Debug_Read(14);
                                    unsigned long ob_out_flags  = Parser_Debug_Read(15);
                                    unsigned long ob_out_action = (ob_out_flags >> 2) & 0x3;

                                    int ob_out_valid = ob_out_flags & 1;
                                    int ob_out_side  = (ob_out_flags >> 1) & 1;

                                    printf("[OB PIPELINE OUTPUT]\n");
                                    printf("   -> Valid    : %s\n", ob_out_valid ? "YES" : "NO");
                                    printf("   -> Side     : %s\n", ob_out_side ? "SELL" : "BUY");
                                    printf("   -> Action   : ");
                                    switch(ob_out_action) {
                                        case 0: printf("ADD\n"); break;
                                        case 1: printf("CANCEL\n"); break;
                                        case 2: printf("EXECUTE\n"); break;
                                        case 3: printf("DELETE\n"); break;
                                    }
                                    printf("   -> Price    : $%.2f  (raw=%lu)\n", ob_out_price / 100.0, ob_out_price);
                                    printf("   -> Quantity : %lu shares\n", ob_out_qty);
                                    // ------------------------------------

                                    printf("[TIMESTAMP] %llu ns  (%.6f s into day)\n",
                                           timestamp_ns, timestamp_ns / 1000000000.0);
                                    printf("[TRADING LOGIC OUTPUT]\n");
                                    printf("   -> Valid     : %s\n", ((ob_status >> 2) & 1) ? "YES" : "NO");
                                    printf("   -> Quote BID : $%.2f\n", trading_bid / 100.0);
                                    printf("   -> Quote ASK : $%.2f\n", trading_ask / 100.0);
                                    printf("[INVENTORY / P&L]\n");
                                    printf("   -> Position        : %ld shares\n", (long)position);
                                    printf("   -> Day Cash P/L    : $%.2f  (raw cents=%lld)\n", day_pnl / 100.0, day_pnl);
                                    printf("   -> Inventory Value : $%.2f  (raw cents=%lld)\n", inventory_value / 100.0, inventory_value);
                                    printf("   -> Total MTM P/L   : $%.2f  (raw cents=%lld)\n", mtm_total_pnl / 100.0, mtm_total_pnl);
                                    printf("   -> Mark Price      : $%.2f\n", mark_price / 100.0);
                                    printf("   -> Live Quote Qty  : bid=%lu ask=%lu\n", live_bid_qty, live_ask_qty);
                                    printf("[COUNTERS]\n");
                                    printf("   -> OUCH order payloads : %lu\n", order_payload_count);
                                    printf("   -> Executions tracked  : %lu\n", exec_count);
                                    printf("   -> Risk rejects        : bid=%lu ask=%lu\n", bid_reject_count, ask_reject_count);
                                     // ---- Per-packet OUCH poll ----
                                     // Inside loop so auto-mode catches each order individually.
                                     usleep(10);
                                     unsigned long cur_ouch = *(h2p_lw_parser_addr + 58);
                                     if (cur_ouch != last_seen_order_count) {
                                         uint16_t payload_stock_id = (uint16_t)Parser_Debug_Read(20);
                                         if (payload_stock_id == 0)
                                             payload_stock_id = 1;
                                         printf("\n[OUCH OUT] %lu new order(s) generated (total=%lu)\n",
                                                cur_ouch - last_seen_order_count, cur_ouch);
                                         Send_OUCH_Payload(new_socket, cur_ouch, payload_stock_id);
                                         last_seen_order_count = cur_ouch;
                                         SEG7_Split(last_seen_order_count, last_rx_bytes);
                                         LED_Set(0x200 | (last_seen_order_count & 0x1FF));
                                     }

                                }

                                cached_packet_ptr += total_len;
                            } else {
                                printf("[ERROR] Malformed length or incomplete packet in cache.\n");
                                break;
                            }
                } else {
                    if (!auto_mode && triggered_by != -1) {
                        printf("[EVENT] FPGA KEY%d Pressed! No more packets to echo.\n", triggered_by);
                    }
                    break;
                }
                packets_to_process--;
            }
            
            // (OUCH poll is now handled inside the packet loop above.
            //  This outer check is a fallback for any orders generated
            //  outside of packet processing, e.g. on session start.)
            {
                unsigned long current_order_count = *(h2p_lw_parser_addr + 58);
                if (current_order_count != last_seen_order_count) {
                    uint16_t payload_stock_id = (uint16_t)Parser_Debug_Read(20);
                    if (payload_stock_id == 0)
                        payload_stock_id = 1;
                    printf("\n[OUCH OUT fallback] %lu order(s) caught (total=%lu)\n",
                           current_order_count - last_seen_order_count,
                           current_order_count);
                    Send_OUCH_Payload(new_socket, current_order_count, payload_stock_id);
                    last_seen_order_count = current_order_count;
                    SEG7_Split(last_seen_order_count, last_rx_bytes);
                    LED_Set(0x200 | (last_seen_order_count & 0x1FF));
                }
            }

            // Prevent 100% CPU usage, lower latency slightly if in auto mode
            if (auto_mode) {
                usleep(1000); // 1ms
            } else {
                usleep(10000); // 10ms
            }
        }
        close(new_socket);
    }

    if( munmap( virtual_base, HW_REGS_SPAN ) != 0 ) {
        printf( "ERROR: munmap() failed...\n" );
        close( fd );
        return( 1 );
    }
    close( fd );
    return 0;
}
