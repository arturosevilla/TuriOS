    .text
    .global _start
_start:
    jmp second_stage
header:
    .byte 0xDE, 0xAD, 0xBE, 0xEF
second_stage:
    jmp second_stage

