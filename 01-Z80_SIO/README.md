# Z80 Serial Input / Outupt SIO

This is a basic terminal echo implementation using a Circular Buffer with serial data transmission using the Z80 SIO for the TEC computer.

There are three parts to this program:
1. A Producer - This is data coming from the SIO from an external source.
2. A Consumer - This is the TEC that consumes data on a key press or automatically
3. A Background Task - This is the TEC waiting for a non empty buffer to start a transmit

A Circular Buffer is a finite set of memory that has a pointer to the Head and a pointer to the end off the buffer.  A producer will place data at the head of the buffer, and a consumer will remove data at the tail of the buffer.  Once the head pointer reaches the end of the finite buffer, it will wrap around to the start of the buffer.  Likewise for the tail pointer.  If head pointer reaches the tail pointer, no more data is accepted and the producer will wait until a free spot is available.  If the tail pointer reaches the head pointer, the buffer is empty and the consumer waits.

An issue arises when the head and tail pointer are pointing to the same location.  Is the buffer empty or full?  To determine this, the following logic is applied.

If the head pointer = tail pointer, then the buffer is empty.
If the head pointer + 1 = tail pointer, then the buffer is full.

A simple process of bit masking on the pointers will reset them to the start of the buffer if they reach the end.  Pointer movement and buffer adding/taking is to be done while interrupts are disabled to ensure no data will be corrupted by another interrupt.

The producer with do the following:
 
 - Read the current value of the head pointer
 - If the head pointer + 1 equals the tail pointer, the buffer is full and raise an error
 - Otherwise, store the data in the head position and increase the head pointer

The consumer will do the following:
 - Read the current value of the tail pointer
 - If the tail pointer equals the head pointer the buffer is empty and exit
 - Otherwise, read the data in the tail position and increase the tail pointer


## Serial port Settings for examples

Assuming you construct the circuit and code as per the examples given, the following settings apply:

- TEC clock: 3.6864MHz
- SIO SCLK: Connect to SCLK4
- Serial port: 14400 bps, 8 bit, no partity, 1 stop bit
- For SCLK2, Serial speed is 28,800
- For SCLK, Serial speed is 57,600


## Example Programs

The sio_circular_buffer_echo.z80 program takes any serial input and echoes it back to the sender. This tests basic communication is working.

The sio_circular_buffer_example.z80 program demonstrates the circular buffer as follows:

On the TEC's 7-seg displays, the first two digits display the current buffer size; the last two digits display the last value stored in the buffer. Input any serial data to see the buffer count increase & verify the data inputted.

The middle two digits display the status:

 - 00 : Buffer status OK
 - EE : Buffer is in error state (buffer has overflowed)
 - AA : buffer is in ECHO mode

In ECHO mode, buffer characters are eched back to the sender

Pressing + on the TEC toggles between buffer mode and echo mode.

If you receive a few characters into the buffer, then press +, the contents of the buffer are sent out the serial port, hence 'unloading' the buffer...the 7-seg returns to 00 indicating the buffer has emptied. Press + again to return to buffer mode.

If too many characters are sent to the buffer, the buffer will overflow, and the middle two digitis will display EE indicating the error condition.

