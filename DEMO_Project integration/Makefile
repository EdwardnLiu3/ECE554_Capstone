TARGET = tcp_receiver

# Typical DE1-SoC compiler and flags
CROSS_COMPILE = arm-linux-gnueabihf-
CFLAGS = -g -Wall -static
LDFLAGS = -static
CC = $(CROSS_COMPILE)gcc

build: $(TARGET)

$(TARGET): tcp_receiver.o
	$(CC) $(LDFLAGS) $^ -o $@

%.o : %.c
	$(CC) $(CFLAGS) -c $< -o $@

.PHONY: clean
clean:
	rm -f $(TARGET) *.a *.o *~ 
