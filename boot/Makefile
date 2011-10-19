
bootloader.o: bootloader.s
	gcc -c bootloader.s

installer: tools/install_into_image.c
	gcc -o installer -Wall tools/install_into_image.c

bootloader.bin: bootloader.o
	ld bootloader.o -o bootloader.bin --oformat=binary -Ttext=0x0

boot: boot.o
	ld boot.o -o boot --oformat=binary -Ttext=0x0

disk.img: bootloader.bin installer boot
	dd if=/dev/zero bs=512 count=2880 of=disk.img
	mkfs.msdos disk.img
	./installer bootloader.bin disk.img
	mcopy -i disk.img boot ::boot

clean:
	rm -f *.bin *.o *.img installer boot
