;SIO with Asynchronous Circular Buffer implementation
;
;By Brian Chiha - brian.chiha@gmail.com
;Feb 2021
;
;This is a Proof of work example to implement a Circular Buffer
;with serial data transmission using the Z80 SIO for the TEC computer.
;
;There are three parts to this program:
;1. A Producer - This is data coming from the SIO from an external source.
;2. A Consumer - This is the TEC that consumes data on a key press or automatically
;3. A Background Task - This is the TEC multiplexing the LED Display
;
;A Circular Buffer is a finite set of memory that has a pointer to the Head and a pointer
;to the end off the buffer.  A producer will place data at the head of the buffer, and a
;consumer will remove data at the tail of the buffer.  Once the head pointer reaches the
;end of the finite buffer, it will wrap around to the start of the buffer.  Likewise for
;the tail pointer.  If head pointer reaches the tail pointer, no more data is accepted and
;the producer will wait until a free spot is available.  If the tail pointer reaches the
;head pointer, the buffer is empty and the consumer waits.
;An issue arises when the head and tail pointer are pointing to the same location.  Is
;the buffer empty or full?  To determine this, the following logic is applied.
;If the head pointer = tail pointer, then the buffer is empty.
;If the head pointer + 1 = tail pointer, then the buffer is full.
;A simple process of bit masking on the pointers will reset them to the start of the buffer
;if they reach the end.  Pointer movement and buffer adding/taking is to be done while
;interrupts are disabled to ensure no data will be corrupted by another interrupt.
;
;The producer with do the following:
;
; - Read the current value of the head pointer
; - If the head pointer + 1 equals the tail pointer, the buffer is full and raise an error
; - Otherwise, store the data in the head position and increase the head pointer
;
;The consumer will do the following:
; - Read the current value of the tail pointer
; - If the tail pointer equals the head pointer the buffer is empty and exit
; - Otherwise, read the data in the tail position and increase the tail pointer

;In order to visualize the circular buffer is working, LED will display the current size of the
;buffer, the current byte that the consumer reads and buffer overflow or transmit status flag.
;The producer will activate when data is received.  The consumer will activate on any key press
;and will echo the data back to the terminal.  If the '+' key is pressed, the comsumer will
;switch between Transmit on Key Press, or Transmit automatically if data is available.

;Note on keyboard and Monitor:
;Since Interrupt mode 2 uses the interrrupt register 'I', any monitor that uses this register
;to store the keyboard key pressed will not work with this program.  JMON is the only monitor
;that will work as it doesn't use the interrupt register to store the keyboard key press.
;Hardware wise, for the keyboard to work it requires EITHER a 4k7 resistor between the
;NMI (pin 17 on Z-80) and D6 (pin 10 on the Z-80) OR the DAT (LCD) expanstion board fitted
;to port 3.  The current TEC-1D boards have the JMON MOD resitor connection already there.


;DATA LOCATIONS
LEDSCR:     .EQU     2a00H ;Byte Recieved, Atomic Flag and Buffer size for LED display      (6-bytes)
BUFFCT:     .EQU     2a06H ;Number of bytes active in the buffer                            (1-byte)
BUFFOF:     .EQU     2a07H ;The state of the buffer okay (00), error (EE), auto (AA)        (1-byte)
BYTERE:     .EQU     2a08H ;Current byte received from SIO                                  (1-byte)
AUTOTM:     .EQU     2a09H ;Flag to automatically transmit to SIO, or by key press FF=auto  (1-byte)
KEYPRE:     .EQU     2a0AH ;Key Pressed Flag, 00-False, FF-True                             (1-byte)

;BUFFER CONFIGURATION
CIRBUF:     .EQU     2B00H ;Location of circular buffer
BUFFHD:     .EQU     2D0BH ;Pointer to the Head of the Circular buffer                      (1-byte)
BUFFTL:     .EQU     2D0CH ;Pointer to the Tail of the Circular buffer                      (1-byte)
;BUFFER SIZES, change to suit
BUFF16:     .EQU     0FH   ;16 bytes
BUFF32:     .EQU     1FH   ;32 bytes
BUFF64:     .EQU     3FH   ;64 bytes
BUFF128:    .EQU     7FH   ;128 bytes
BUFF256:    .EQU     0FFH  ;256 bytes
BUFSIZ:     .EQU     BUFF32  ;16 bytes (Change if required)

;SIO TEC PORT CONFIGURATION
;For my setup Port 7 on TEC is connected to CE, A5 is connected to Control/Data,
;and A4 is connected to A/B.  This can be changed to your setup.
;(Note, I skipped A3 because the DAT LCD screen uses it)
SIO_DA:     .EQU     07H   ;Port 7 & Data 'A'
SIO_DB:     .EQU     17H   ;Port 7 & Data 'B'
SIO_CA:     .EQU     27H   ;Port 7 & Control 'A'
SIO_CB:     .EQU     37H   ;Port 7 & Control 'B'

;INTERRUPT VECTOR TABLE SETUP
;The interrupt will call one of these service routines depending on the type of interrupt
;There are 4 reasons the interrupt will occur:
; 1. Transmit Buffer Empty - Indicating that data can be sent to the SIO
; 2. External/Status Change - Indicating a change in the modem line or break condition
; 3. Receive Character Available - Indicating that data has been sent to CPU
; 4. Special Receive Condition - Indicates a buffer overrun or parity error condtion has occured
;
;Interrupt mode 2 (IM 2), requires a 16 bit table of addresses. The High byte of the
;address is the value in the interrupt register 'I'.  The Low byte of the address is
;placed on the data bus from the SIO when an interrupt is triggered. The follwing table
;shows what bits are set on the data bus.  This is used to index the vector table:
;Note: D0, D4-7 are set via Write Register 2 (Channel B on the sio).  this is set to 00H
;
; Channel   D3  D2  D1  Addr  Interrupt type
; -------   --  --  --  ----  --------------
;    B       0   0   0   00H  Transmit Buffer Empty
;    B       0   0   1   02H  External/Status Change
;    B       0   1   0   04H  Receive Character Available
;    B       0   1   1   06H  Special Receive Condition
;    A       1   0   0   08H  Transmit Buffer Empty
;    A       1   0   1   0AH  External/Status Change
;    A       1   1   0   0CH  Receive Character Available
;    A       1   1   1   0EH  Special Receive Condition
;
SIO_IV:     .EQU     2E00H      ;Interrupt Vector Base
SIO_WV:     .EQU     SIO_IV+08H ;Write Interrupt Vector
SIO_EV:     .EQU     SIO_IV+0AH ;External Status Interrupt Vector
SIO_RV:     .EQU     SIO_IV+0CH ;Read Interrupt Vector
SIO_SV:     .EQU     SIO_IV+0EH ;Special Receive Interrupt Vector

            .ORG     02000H
START:
;Initialize interrupt system and SIO
            DI                          ;Disable interrupts

;Initialise interrupt vectors
            LD      HL,SIO_IV           ;Get Interupt high page number
            LD      A,H                 ;Save H in A
            LD      I,A                 ;Set interrupt vector high address (0B)
            IM      2                   ;Interrupt Mode 2, Vector in table

;Link interrupt vector address to handler routines
            LD      HL,READ_HANDLE      ;Store Read Vector
            LD      (SIO_RV),HL         ;
            LD      HL,WRITE_HANDLE     ;Store Write Vector
            LD      (SIO_WV),HL         ;
            LD      HL,EXTERNAL_HANDLE  ;Store External Status Vector
            LD      (SIO_EV),HL         ;
            LD      HL,ERROR_HANDLE     ;Store Receive Error Vector
            LD      (SIO_SV),HL         ;

;Initialise the SIO
            CALL    INIT_SIO            ;Set up the SIO

;Initialise Screen and other data
            XOR     A                   ;Reset A
            LD      HL,BUFFCT           ;Buffer count
            LD      B,04H               ;Four Bytes to clear/set
S1:
            LD      (HL),A              ;Load 0 to HL
            INC     HL                  ;Move to next address
            DJNZ    S1                  ;Do 3 times
;Set Buffer Head and Tail pointers based of LSB of circular buffer
            LD      HL,CIRBUF           ;Load Circular buffer address
            LD      A,L                 ;Head/Tail = LSB of buffer
            LD      (BUFFHD),A          ;Save initial Head pointer
            LD      (BUFFTL),A          ;Save initial Tail pointer

            EI                          ;Enable Interrrupts

;Start Background task of updating the screen buffer and multiplexing the LED's
;This will loop continually until the SIO sends an interrupt.
WAIT_LOOP:
            CALL    KEY_READ            ;Read the keyboard
            CALL    UPDATE_LED          ;Update the screen buffer
            CALL    SCAN                ;Display the Screen Buffer
            LD      A,(AUTOTM)          ;Check for automatic transmit
            OR      A                   ;Is it set?
            JR      Z,WAIT_LOOP         ;No, just repeat
            CALL    DO_TRANSMIT         ;Check for non empty buffer and transmit
            JR      WAIT_LOOP

;SIO Interrupt Handlers
;----------------------
;These four routines handle the four interrupts that the SIO produces.  See above.
;When an Intrrupt is triggered, the CPU automaticaly disables interrupts, ensuring
;no other intrrupts occur when one is being handled.  Before exiting the routine,
;interrupts are to be reenabled.  RETI (Return from interrupt) is the same as RET but
;the SIO recognises this instruction indicating that the interrupt routined has ended.

;Receive Character Available Interrupt handler
READ_HANDLE:
            PUSH    AF                  ;Save AF
;Check if buffer is full?
            LD      A,(BUFFHD)          ;Get the HEAD pointer
            LD      B,A                 ;Save in B
            LD      A,(BUFFTL)          ;Get the TAIL pointer
            DEC     A                   ;Decrease it by one
            AND     BUFSIZ              ;Mask for wrap around
            CP      B                   ;Is HEAD = TAIL - 1?
            JR      NZ,READ_OKAY        ;Different so save to buffer
;Buffer is full
            LD      A,0EEH              ;Buffer is full
            LD      (BUFFOF),A          ;Put EE in BUFF overflow
            IN      A,(SIO_DA)          ;Read overflow byte to clear interrupt
            LD      (BYTERE),A          ;Save data in input buffer
            JR      READ_EXIT           ;Exit Safely
;Buffer in not full
READ_OKAY:
            IN      A,(SIO_DA)          ;Read data from SIO
            LD      (BYTERE),A          ;Save data in input buffer
            LD      HL,CIRBUF           ;Load Buffer in HL
            LD      L,B                 ;Load Head Pointer to L to index the Circular Buffer
            LD      (HL),A              ;Save Data at head of buffer

            LD      A,L                 ;Load Head Pointer to A
            INC     A                   ;Increase Head pointer by 1
            AND     BUFSIZ              ;Mask for wrap around
            LD      (BUFFHD),A          ;Save new head

            LD      HL,BUFFCT           ;Load the current buffer count
            INC     (HL)                ;Increase the buffer count by 1

READ_EXIT:
            POP     AF                  ;Restore AF
            EI                          ;Reenable Interrupts
            RETI                        ;Return from Interrupt

;Transmit Buffer Empty Interrupt Handler, When a character is transmitted, this
;interrupt will be called when the SIO clears its buffer.  It then checks for
;more data to send.  If no more data is to be sent, to stop this interrupt from
;being repeatingly triggered, a command to reset the Transmit interrupt is sent
WRITE_HANDLE:
            PUSH    AF                  ;Save AF
            LD      A,(AUTOTM)          ;Check Automatic Transmit Flag
            OR      A                   ;If Zero then just dont transmit
            JR      Z,TRANS_RESET       ;Reset transmit interrupt
            CALL    DO_TRANSMIT         ;Do the Transmit, Carry flag is set if buffer is empty
            JR      NC,WRITE_EXIT       ;Data was tramitted, Exit Safely
TRANS_RESET:
;Buffer is Empty, reset transmit interrupt
            LD      A,00101000B         ;Reset SIO Transmit Interrupt
            OUT     (SIO_CA),A          ;Write into WR0
WRITE_EXIT:
            POP     AF                  ;Restore AF
            EI                          ;Reenable Interrupts
            RETI                        ;Return from Interrupt

;External Status/Change Interrupt Handler.  Not handled, Just reset the status interrupt
EXTERNAL_HANDLE:
            PUSH    AF                  ;Save AF
            LD      A,00010000B         ;Reset Status Interrupt
            OUT     (SIO_CA),A          ;Write into WR0
            POP     AF                  ;Restore AF
            EI                          ;Reenable Interrupts
            RETI                        ;Return from Interrupt

;Special Receive Interrupt Handler.  Not handled, Just reset the status interrupt
ERROR_HANDLE:
            PUSH    AF                  ;Save AF
            LD      A,00110000B         ;Reset Receive Error Interrupt
            OUT     (SIO_CA),A          ;Write into WR0
            POP     AF                  ;Restore AF
            EI                          ;Reenable Interrupts
            RETI                        ;Return from Interrupt

;Consume one byte if any to consume
DO_TRANSMIT:
            DI                          ;Disable interrupts
;Check if buffer is empty?
            LD      A,(BUFFTL)          ;Get the TAIL pointer
            LD      B,A                 ;Save in B
            LD      A,(BUFFHD)          ;Get the HEAD pointer
            CP      B                   ;Does TAIL=HEAD?
            JR      NZ,WRITE_OKAY       ;No, Transmit data at Tail
;Buffer is Empty, set the carry flag and exit
            SCF                         ;Set the Carry Flag
            EI                          ;Restore interrupts
            RET                         ;Exit
;Buffer is not empty
WRITE_OKAY:
            LD      HL,CIRBUF           ;Load Buffer in HL
            LD      L,B                 ;Load Tail Pointer to L to index the Circular Buffer
            LD      A,(HL)              ;Get byte at Tail.
            OUT     (SIO_DA),A          ;Transmit byte to SIO
;Output has occured
            LD      A,L                 ;Load Tail Pointer to A
            INC     A                   ;Increase Tail pointer by 1
            AND     BUFSIZ              ;Mask for wrap around
            LD      (BUFFTL),A          ;Save new tail

            LD      HL,BUFFCT           ;Load the current buffer count
            DEC     (HL)                ;Decrease the buffer count by 1

            OR      A                   ;Reset Carry Flag
            EI                          ;Restore interrupts
            RET                         ;Exit

;SIO Configuration Routines
;--------------------------

INIT_SIO:
            LD      HL,CTLTBL           ;Setup data location
            CALL    IPORTS              ;Setup the SIO
            RET                         ;Exit

;Initialize the SIO, Requires 3 bits of information. Number of control bytes to send,
;the port to send it to and the control data.
IPORTS:
            LD      A,(HL)              ;Load Control Table (Bytes)
            OR      A                   ;Test for zero, no more data to load
            RET     Z                   ;Return if zero
            LD      B,A                 ;Save number of control bytes in B
            INC     HL                  ;Move to Port address
            LD      C,(HL)              ;Load C with port address (for OTIR)
            INC     HL                  ;Move to control data

            OTIR                        ;Output HL data, B times, to port C
            JR      IPORTS              ;Jump to the next port

;Control Table data for SIO. Refer to Z80 SIO Technical Manual for more information
;on the bits set.
CTLTBL:
;Reset Channel A
            .DB 01H                      ;1 Line
            .DB SIO_CA                   ;A Port Command
            .DB 00011000B                ;write into WR0: channel reset

;Set Interrupt Vector and allow status to affect it. The WR2 allows the user to set
;the default base address of the vector table. Bits 1,2 and 3 are set based on the
;interrupt.  The other bits can be set here, Since my vector tables starts at 0B00,
;thie register can just be set to 0;
            .DB 04H                      ;4 Lines
            .DB SIO_CB                   ;B Port Command
            .DB 00000010B                ;write into WR0: select WR2
            .DB 00000000B                ;write into WR2: set base interrupt vector for SIO (0B00)
            .DB 00000001B                ;write into WR0: select WR1
            .DB 00000100B                ;write into WR1: allow status to affect vector

;Initialise Channel A
            .DB 08H                      ;8 Lines
            .DB SIO_CA                   ;A Port Command
            .DB 00010100B                ;write into WR0: select WR4 / Reset Int
            .DB 11000100B                ;write into WR4: presc. 64x, 1 stop bit, no parity
            .DB 00000011B                ;write into WR0: select WR3
            .DB 11000001B                ;write into WR3: 8 bits/RX char; auto enable OFF; RX enable
            .DB 00000101B                ;write into WR0: select WR5
            .DB 01101010B                ;write into WR5: TX 8 bits, TX Enable, No RTS
            .DB 00000001B                ;write into WR0: select WR1
            .DB 00011011B                ;write into WR1: Int on All RX (No Parity), TX Int, Ex Int

            .DB 00H                      ;End Initialisation Array

;Background Utilities
;--------------------

;Scan the Keyboard for input.  If anykey is pressed except for '+', transmit data from the
;circular buffer to the SIO if data is available.  If '+' is pressed, toggle the auto
;transmit flag. Must
KEY_READ:
            IN      A,(00)              ;Check if key is pressed
            BIT     6,A                 ;If bit 6 is set (D6) the key has been pressed
            JR      Z,K1                ;Key pressed, action it
            XOR     A                   ;Store 0 for last key if no key pressed
            LD      (KEYPRE),A          ;
            RET                         ;Exit
K1:
;Key has been pressed
            LD      A,(KEYPRE)          ;Check if it was the same
            OR      A                   ;
            RET     NZ                  ;Just return if same
            LD      A,0FFH
            LD      (KEYPRE),A          ;Store FF in key press
            IN      A,(00)              ;Get actual key
            AND     1FH                 ;Mask upper bits

            CP      10H                 ;Has the '+' key been pressed?
            JP      NZ,DO_TRANSMIT      ;No, Jump to Transmit Byte routine and exit

;+ Pressed, toggle the auto transmit flag
            LD      A,(AUTOTM)          ;Get the Automatic transmit flag
            CPL                         ;toggle it
            LD      (AUTOTM),A          ;Store toggled value back
            LD      A,(BUFFOF)          ;Get the state of the Buffer
            XOR     0AAH                ;Toggle it (00) or (AA)
            LD      (BUFFOF),A          ;Store toggled value back
            RET                         ;Exit

;Multiplex the Display
SCAN:                                   ;Multiplex the displays
            LD      B,20H               ;Segment Reference
            LD      HL,LEDSCR           ;Set HL to Display Buffer

SCAN_LOOP:
            LD      A,(HL)              ;Get Segment Value at HL
            OUT     (02),A              ;Set on Segment
            LD      A,B                 ;Get Segment reference
            OUT     (01),A              ;Activate segment
            LD      B,80H               ;Segment delay
D_LOOP:     DJNZ    D_LOOP
            INC     HL                  ;move to next location
            LD      B,A                 ;Save Segment reference
            XOR     A                   ;Clear A
            OUT     (01),A              ;Deactivate Segment
            RRC     B                   ;Move Segment Reference on to the Right
            JR      NC,SCAN_LOOP        ;If not passed the last segment, scan next segment
            OUT     (02),A              ;Clear port 2
            RET

;Update the LEDSCR with Byte Received, Atomic Flag and Buffer size
UPDATE_LED:
            LD      BC,LEDSCR           ;Location of screen buffer
            LD      HL,BUFFCT           ;Byte Recieved
            LD      A,(HL)
            CALL    CON_A               ;Convert A to Segment Hex, Store in BC
            INC     HL
            LD      A,(HL)              ;Atomic Flag
            CALL    CON_A               ;Convert A to Segment Hex, Store in BC
            INC     HL
            LD      A,(HL)              ;Buffer count
            CALL    CON_A               ;Convert A to Segment Hex, Store in BC
            RET

;Convert A to two display bytes for Seven Segment, Store Result in location of BC
CON_A:
            PUSH    AF                  ;Save A to keep original value
            RLCA                        ;Shift upper nibble to lower for masking
            RLCA
            RLCA
            RLCA
            CALL    CON_NIBBLE          ;Convert Lower nibble to segment hex
            POP     AF                  ;Restore A

CON_NIBBLE:
            AND     0FH                 ;Only look at lower nibble for indexing
            LD      DE,DISP_COD_TAB     ;Reference Segment convert table
            ADD     A,E                 ;Index table with A
            LD      E,A                 ;Update DE with index
            LD      A,(DE)              ;Look up table
            LD      (BC),A              ;Save it to display buffer
            INC     BC                  ;Increment buffer location
            RET

;Hex to Seven Segment lookup table
DISP_COD_TAB:
            .DB      0EBH,028H,0CDH,0ADH,02EH,0A7H,0E7H,029H
            .DB      0EFH,0AFH,06FH,0E6H,0C3H,0ECH,0C7H,047H

	    .end

