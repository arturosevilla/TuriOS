#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>

/* This program only works for partition image files
   WARNING: Will overwrite MBR images!
*/

#define BOOTRECORD_SIZE 512
#define MAX_BOOTCODE_SIZE(fat_size) (BOOTRECORD_SIZE - (fat_size) - 2)

static unsigned char nop_slide[] = {
    0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90,
    0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90,
    0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90
};

void help(char *progname)
{
    fprintf(stderr, "%s: bootloader image\n", progname);
    fprintf(stderr, "bootloader should have the correct size for the image\n");
}

int detect_fat_size(FILE *image_file)
{
    /* just a quick detection scheme. I know that do it correctly, you must
       parse the total clusters and determine the FAT version. */
    unsigned char preamble[3];
    if (!image_file) {
        return -1;
    }

    rewind(image_file);
    if (fread(preamble, 1, 3, image_file) != 3) {
        return -1;
    }

    if (preamble[0] == 0xEB && preamble[2] == 0x90) {
        return preamble[1] + 2;
    }

    return -1;
}

inline int nop_slide_size(int fat_size)
{
    return fat_size - (fat_size & ~ 3U);
}

int copy_bootcode_into_image(FILE *boot_file, FILE *image_file,
                             size_t bootcode_size, int fat_size)
{
    char *boot_code = malloc(bootcode_size);
    char boot_signature[2] = { 0x55, 0xAA };
    /* nop slide for word alignment */
    unsigned int nop_size = nop_slide_size(fat_size);
    if (!boot_code) {
        fprintf(stderr, "Unsufficient memory\n");
        exit(EXIT_FAILURE);
    }

    if (fread(boot_code, 1, bootcode_size, boot_file) != bootcode_size) {
        goto error;
    }

    if (fseek(image_file, fat_size, SEEK_SET) < 0) {
        goto error;
    }

    if (fwrite(nop_slide, 1, nop_size, image_file) != nop_size) {
        goto error;
    }

    if (fwrite(boot_code, 1, bootcode_size, image_file) != bootcode_size) {
        goto error;
    }

    if (fseek(image_file, BOOTRECORD_SIZE - 2, SEEK_SET) < 0) {
        goto error;
    }

    if (fwrite(boot_signature, 1, 2, image_file) != 2) {
        goto error;
    }

    free(boot_code);
    return 0;
error:
    if (boot_code) {
        free(boot_code);
    }

    return -1;
}

int main(int argc, char **argv)
{
    struct stat bootloader_stats, image_stats;
    FILE *image_file, *boot_file;
    int fat_size;
    size_t bootcode_size;

    if (argc != 3) {
        help(argv[0]);
        return EXIT_FAILURE;
    }

    if (stat(argv[1], &bootloader_stats) ||
        !S_ISREG(bootloader_stats.st_mode)) {
        help(argv[0]);
        return EXIT_FAILURE;
    }

    if (stat(argv[2], &image_stats) || !S_ISREG(image_stats.st_mode)) {
        help(argv[0]);
        return EXIT_FAILURE;
    }

    image_file = fopen(argv[2], "r+");
    if (!image_file) {
        help(argv[0]);
        return EXIT_FAILURE;
    }

    fat_size = detect_fat_size(image_file);
    if (fat_size < 0) {
        fclose(image_file);
        fprintf(stderr, "Unable to detect FAT type\n");
        help(argv[0]);
        return EXIT_FAILURE;
    }

    bootcode_size = bootloader_stats.st_size;

    if (bootcode_size > MAX_BOOTCODE_SIZE(fat_size) -
            nop_slide_size(fat_size)) {
        fclose(image_file);
        fprintf(stderr, "Impossible to fit bootloader code into image\n");
        help(argv[0]);
        return EXIT_FAILURE;
    }

    if (image_stats.st_size < BOOTRECORD_SIZE) {
        fclose(image_file);
        fprintf(stderr, "Impossible bootable geometry for image\n");
        help(argv[0]);
        return EXIT_FAILURE;
    }

    boot_file = fopen(argv[1], "r");
    if (!boot_file) {
        fclose(image_file);
        help(argv[0]);
        return EXIT_FAILURE;
    }

    if (copy_bootcode_into_image(boot_file, image_file, bootcode_size,
                                 fat_size)) {
        fclose(image_file);
        fclose(boot_file);
        fprintf(stderr, "Error while copying. Possible corruption of image"
                        "file\n");
        return EXIT_FAILURE;
    }

    fclose(image_file);
    fclose(boot_file);
    return 0;
}

