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
                
                // Display the new packet length on the HEX display
                SEG7_Decimal(valread);
                // Optional: set LED based on the length
                LED_Set(valread);
            } else if (valread == 0) {
                printf("[INFO] Client disconnected.\n");
                break;
            }

            // 2. Poll FPGA Physical Buttons
            unsigned long current_button_state = *h2p_lw_button_addr & 0xF;
            
            // Edge detection (only trigger once per press)
            if (current_button_state != last_button_state) {
                for (int i=0; i<4; i++) {
                    // Active low: Went from 1 (unpressed) to 0 (pressed)
                    if (((last_button_state >> i) & 1) && !((current_button_state >> i) & 1)) {
                        if (cached_packet_ptr < cached_packet_len) {
                            // Extract SoupBinTCP 2-byte length
                            int msg_len = (cached_packet[cached_packet_ptr] << 8) | cached_packet[cached_packet_ptr+1];
                            int total_len = msg_len + 2;
                            
                            // Bounds check
                            if (cached_packet_ptr + total_len <= cached_packet_len) {
                                printf("\n======================================================\n");
                                printf("[EVENT] FPGA KEY%d Pressed! Feeding packet to HW PARSER...\n", i);
                                
                                // Strip the 3-byte SoupBinTCP framing
                                if (msg_len >= 1) {
                                    int payload_len = msg_len - 1; // subtract 'S' byte
                                    unsigned char* payload = &cached_packet[cached_packet_ptr + 3];
                                    
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

                                }

                                // We still send the raw data to Python client just to clear queue 
                                send(new_socket, cached_packet + cached_packet_ptr, total_len, 0);
                                cached_packet_ptr += total_len;
                            } else {
                                printf("[ERROR] Malformed length or incomplete packet in cache.\n");
                            }
                        } else {
                            printf("[EVENT] FPGA KEY%d Pressed! No more packets to echo.\n", i);
                        }
                    }
                }
                last_button_state = current_button_state;
            }
            
            // Prevent 100% CPU usage
            usleep(10000); // 10ms
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
