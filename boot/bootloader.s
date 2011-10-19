BOOTSEG = 0x07C0
COPY_BOOT_SEG = 0x800 # just 1 KB above boot for the stack.
SECOND_BOOTLOADER_SEG = 0xA60 # 0x8000 + 512*9*2 + 512 (FAT tbls and boot sect)
STACK_SPACE = 0x400 # 1 KB
MAX_COL = 80
MAX_ROW = 25
DISK_GEO_SPACE = 0x42 # we need at leas 0x42 bytes for 0x48 ext BIOS method
BOOT_SECTOR_SIZE = 512
FAT32_HEADER_SIZE = 90 

    .code16
    .text
    .global _start
_start: # so ld doesn't complain
    cli # bye bye world
    # first we copy ourselves so we don't have problems with alignment or
    # memory addressing due to linking. In this way we have the freedom to
    # "link ourselves" to where ever we want.
    # First lets set our stack
    movw $BOOTSEG, %ax
    movw %ax, %ds
    movw %ax, %ss
    movl $STACK_SPACE, %esp # 1 KB of stack
    movl %esp, %ebp
    # Then let's calculate our offset from the boot sector
    # This offset is created because of the FAT headers
    call get_our_ip
absolute_offset_from_start:
    movl $(absolute_offset_from_start - _start), %ebx
    subl %ebx, %eax
    subl $(BOOTSEG << 4), %eax
    # Finally set our pointers and copy!
    cld
    xorw %di, %di
    movw $COPY_BOOT_SEG, %bx
    movw %bx, %es # copy into %es:%di
    movw %ax, %si # from %ds:%si
    movw $(end_boot_code - _start), %cx
    rep
    movsb

    ljmp $COPY_BOOT_SEG, $boot # jump into the copied code
kernel_name:
    .ascii "BOOT       " # 8.3 format, but I don't use an extension ;)
error_loading:
    .asciz "ERROR: Press key to reboot."
get_our_ip:
    mov (%esp), %eax
    ret
total_sectors_per_track:
    .long 0
total_heads:
    .long 0
after_root_entries:
    .short 0
device:
    .byte 0
boot:
    # set the required segments
    movw %es, %ax # After the copy, %es will contain our data segment
    movw %ax, %ds # segment used for BIOS functions
    movw %ax, %fs
    sti # hello world, again!
    # %ah = 0, so we reset our disk controller
    # assume %dl is correctly set
    # but first save our device
    movb %dl, device
    call reset_disk
    xorw %ax, %ax
    int $0x13

    # Get the %dl disk geometry
read_floppy:
    xorw %ax, %ax
    pushw %es
    movw %ax, %es
    movb $0x8, %ah
    xorw %di, %di # workaround for buggy BIOS es:di = 0
    movb device, %dl

    int $0x13
    popw %es
    jnc read_floppy_ok # CF is set on error
    jmp bad_setup # :(

read_floppy_ok:
    andl $0x3F, %ecx # sectors/track is stored in the first six bits of %cx
    movl %ecx, total_sectors_per_track
    movzbl %dh, %ecx
    incl %ecx # %dh really contains the last index of heads
    movl %ecx, total_heads

finish_disk_geometry:
    # Assume:
    # * 512 bytes in sector for floppies
    # * 1 boot sector
    # * 1 sector per cluster
    # * 9 sectors per fat
    # * 2 FAT tables in floppy
    # Then:
    # * first_data_sector = num_boot_sectors + fat_tables * sectors_per_fat
    #   = 19
    # We also know that there are 32 bytes per entry in the directory and that
    # there are 512 bytes per sector in floppies, so in order to know how many
    # sectors to read for the root directory: << 5 >> 9 = >> 4
    cli
    pushw %ds
    movw $BOOTSEG, %cx
    movw %cx, %ds # Gets the number of dir entries from the FAT sector
    movw 17, %cx # At offset 17
    popw %ds
    sti
    
    pushw %cx # store our root dir entries
    movw $19, %ax # we read our first data sector
    shrw $4, %cx # and ecx >> 4 number of them
    movw %cx, after_root_entries # store it for later use
    movw $end_boot_code, %bx # after our code
    call read_sector

    popw %cx
    addw $3, %bx
    andw $~3, %bx
    movw %bx, %di
    cld
search_in_dir:
    pushw %di
    xchgw %cx, %ax # we need %cx for comparison

    movw $kernel_name, %si
    movw $11, %cx # 8.3 format
    rep
    cmpsb
    je kernel_found
    
    popw %di
    addw $32, %di # we advance to our next entry

    xchgw %ax, %cx
    loop search_in_dir
    jmp bad_setup

kernel_found:
    movw after_root_entries, %cx
    addw $19, %cx # see below for the equation
    movw %cx, after_root_entries

    # We get the first cluster number
    popw %di
    movw 26(%di), %ax # For FAT floppies use the low 16 bits of the cluster


    # Now we read the FAT
    push %ax
    movw $1, %ax
    movw $9, %cx # remember we assume 9 sectors per FAT

    movw $end_boot_code, %bx # after our code
    call read_sector
    pop %ax

    movw $SECOND_BOOTLOADER_SEG, %bx
    movw %bx, %es # prepare to copy our second stage bootloader clusters

    xorw %bx, %bx # we prepare our pointer for kernel loading
    
load_kernel:
    # fat_sector = (cluster - 2) * sectors_per_cluster + start_of_data
    # fat_sector = (cluster - 2) + 19 + dir_entries >> 4 (see above)
    # 
    pushw %ax # for our cluster chain calculation
    # Load our sector into the new segment
    movw after_root_entries, %cx
    leal -2(%ecx, %eax), %eax # %ax = %ax - 2 + %cx
    movw $1, %cx
    call read_sector
    addw $512, %bx # we update our pointer

    # Calculate our next cluster in the chain
    # fat_offset = (cluster * 3) / 2;
    # fat_sector = first_fat_sector + fat_offset / cluster_size; 
    # but cluster_size = 1 so:
    # fat_sector = first_fat_sector + fat_offset
    # we assume fat_sector is already loaded and that is our FAT table
    # ent_offset = fat_offset % cluster_size = fat_offset
    popw %ax
    movw %ax, %bx
    xorw %dx, %dx
    movw $3, %cx
    mulw %cx
    shrw $1, %ax
    movw $end_boot_code, %si # we need to align to our buffer
    addw $3, %si
    andw $~3, %si
    add %ax, %si
    movw (%si), %ax
    # if current_cluster & 0x1:
    #    %ax >>= 4;
    # else:
    #    %ax &= 0x0FFF;
    testw $0x1, %bx
    jz low_data
    shrw $4, %ax
    jmp next_cluster
low_data:
    andw $0x0FFF, %ax
next_cluster:
    cmpw $0xFF8, %ax
    jae run_kernel
    jmp load_kernel

run_kernel:
    movb device, %dl
    ljmp $SECOND_BOOTLOADER_SEG, $0
 
# --------- END OF BOOTLOADER CODE -------- #
    
bad_setup:
    # reboot
    movw $error_loading, %si
    call display_to_screen
    xorw %ax, %ax
    int $0x16 # press any key to reboot...
    int $0x19

display_to_screen:
    cld
loop_print:
    lodsb
    test %al, %al
    jz finish_display
    movb $0xe, %ah
    int $0x10

    jmp loop_print

finish_display:
    ret

from_logical_to_physical_sector:
    xorl %edx, %edx
    divl total_sectors_per_track
        
    movb %dl, %cl
    incb %cl # 1 + (fat_sector % sectors_per_track)
    
    xorl %edx, %edx
    divl total_heads
    movb %al, %ch # (fat_sector / sectors_per_track) / total_heads
    movb %dl, %dh # (fat_sector / sectors_per_track) % total_heads

    ret

reset_disk:
    # This routine resets our disk.
    # Floppies are very prone to read failure, so we always give them a second
    # chance.
    movb device, %dl
    xorw %ax, %ax
    int $0x13
    jc bad_setup
    ret

read_sector:
    # This BIOS call will store our data in %es:%bx
    # Receives logical sector in %ax, and count in %cl
    pusha
    addw $3, %bx
    andw $~3, %bx # align for word boundary
    pushw %bx
    movw %cx, %bx # bx is not touched by the following function
    call from_logical_to_physical_sector
    movb %bl, %al
    movb $0x2, %ah
    movb device, %dl
    popw %bx

    stc # for buggy BIOS
    int $0x13
    jnc finish_read_sector
    call reset_disk
    call read_sector # This might get us a stack overflow, but i don't care :)
finish_read_sector:
    popa
    ret

end_boot_code:
