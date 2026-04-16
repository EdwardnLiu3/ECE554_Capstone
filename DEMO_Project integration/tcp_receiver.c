#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/mman.h>
#include <stdbool.h>
#include <string.h>
#include <ctype.h>
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
                                    
                                    // 4. Read parser outputs (address 10-14)
                                    unsigned long out_order_id_lo = *(h2p_lw_parser_addr + 10);
                                    unsigned long out_qty   = *(h2p_lw_parser_addr + 12);
                                    unsigned long out_price = *(h2p_lw_parser_addr + 13);
                                    unsigned long out_flags = *(h2p_lw_parser_addr + 14);

                                    // Read orderbook outputs (address 15-21)
                                    unsigned long ob_bid_price     = *(h2p_lw_parser_addr + 15);
                                    unsigned long ob_bid_quant_lo  = *(h2p_lw_parser_addr + 16);
                                    unsigned long ob_bid_quant_hi  = *(h2p_lw_parser_addr + 17);
                                    unsigned long ob_ask_price     = *(h2p_lw_parser_addr + 18);
                                    unsigned long ob_ask_quant_lo  = *(h2p_lw_parser_addr + 19);
                                    unsigned long ob_ask_quant_hi  = *(h2p_lw_parser_addr + 20);
                                    unsigned long ob_valid_flags   = *(h2p_lw_parser_addr + 21);

                                    // Parser now outputs native-endian values (byte-swapped in hardware).
                                    int is_valid = (out_flags >> 19) & 1;
                                    int side     = (out_flags >> 18) & 1;
                                    int action   = (out_flags >> 16) & 3;

                                    printf("[HW PARSER OUTPUT] Valid? %s (Pulse Died)\n", is_valid ? "YES" : "NO");

                                    printf("   -> Order ID : %lu\n", out_order_id_lo);
                                    printf("   -> Action   : ");
                                    switch(action) {
                                        case 0: printf("ADD\n"); break;
                                        case 1: printf("CANCEL\n"); break;
                                        case 2: printf("EXECUTE\n"); break;
                                        case 3: printf("DELETE\n"); break;
                                    }
                                    printf("   -> Side     : %s\n", side ? "SELL" : "BUY");
                                    printf("   -> Quantity : %lu shares\n", out_qty);
                                    printf("   -> Price    : $%.4f\n", out_price / 10000.0);

                                    // Print orderbook best bid/ask state
                                    int ob_bid_valid = ob_valid_flags & 1;
                                    int ob_ask_valid = (ob_valid_flags >> 1) & 1;
                                    unsigned long long ob_bid_quant = ((unsigned long long)ob_bid_quant_hi << 32) | ob_bid_quant_lo;
                                    unsigned long long ob_ask_quant = ((unsigned long long)ob_ask_quant_hi << 32) | ob_ask_quant_lo;

                                    printf("[ORDERBOOK STATE]\n");
                                    if (ob_bid_valid) {
                                        // ob_bid_price = cache index = raw_price/100; raw_price in units of 0.0001 dollars
                                        printf("   -> Best BID : price=$%.2f  qty=%llu\n", ob_bid_price / 100.0, ob_bid_quant);
                                    } else {
                                        printf("   -> Best BID : (empty)\n");
                                    }
                                    if (ob_ask_valid) {
                                        printf("   -> Best ASK : price=$%.2f  qty=%llu\n", ob_ask_price / 100.0, ob_ask_quant);
                                    } else {
                                        printf("   -> Best ASK : (empty)\n");
                                    }

                                    // ---- RAW ORDERBOOK INPUT DEBUG ----
                                    // Read what the parser actually sent into the orderbook
                                    // Give one extra cycle for signals to settle
                                    usleep(1);
                                    unsigned long ob_in_order_id = *(h2p_lw_parser_addr + 23);
                                    unsigned long ob_in_price    = *(h2p_lw_parser_addr + 24);
                                    unsigned long ob_in_qty      = *(h2p_lw_parser_addr + 25);
                                    unsigned long ob_in_flags    = *(h2p_lw_parser_addr + 26);
                                    unsigned long ob_in_action   = *(h2p_lw_parser_addr + 27) & 0x3;

                                    int ob_in_valid  = (ob_in_flags >> 2) & 1;
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
                                    printf("   -> OB Price    : $%.4f  (raw=%lu)\n", ob_in_price / 10000.0, ob_in_price);
                                    printf("   -> OB Valid    : %s\n", ob_in_valid ? "YES" : "NO (latched after pulse)");
                                    // ------------------------------------

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
