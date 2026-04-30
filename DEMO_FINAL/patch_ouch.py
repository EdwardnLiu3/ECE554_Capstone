src = open('tcp_receiver.c', 'rb').read().decode('utf-8')

ouch_insert = (
    '\r\n'
    '                                     // ---- Per-packet OUCH poll ----\r\n'
    '                                     // Inside loop so auto-mode catches each order individually.\r\n'
    '                                     usleep(10);\r\n'
    '                                     unsigned long cur_ouch = *(h2p_lw_parser_addr + 58);\r\n'
    '                                     if (cur_ouch != last_seen_order_count) {\r\n'
    '                                         printf("\\n[OUCH OUT] %lu new order(s) generated (total=%lu)\\n",\r\n'
    '                                                cur_ouch - last_seen_order_count, cur_ouch);\r\n'
    '                                         Send_OUCH_Payload(new_socket, cur_ouch);\r\n'
    '                                         last_seen_order_count = cur_ouch;\r\n'
    '                                         SEG7_Split(last_seen_order_count, last_rx_bytes);\r\n'
    '                                         LED_Set(0x200 | (last_seen_order_count & 0x1FF));\r\n'
    '                                     }'
)

# The exact text that ends the msg_len block, right before "// We still send"
old = 'ask_reject_count);\r\n\r\n                                }\r\n\r\n                                // We still send'
new_s = 'ask_reject_count);' + ouch_insert + '\r\n\r\n                                }\r\n\r\n                                // We still send'

if old in src:
    src2 = src.replace(old, new_s, 1)
    open('tcp_receiver.c', 'wb').write(src2.encode('utf-8'))
    print('SUCCESS: per-packet OUCH poll inserted inside loop')
else:
    print('ERROR: marker not found')
    idx = src.find('ask_reject_count')
    print(repr(src[idx:idx+100]))
