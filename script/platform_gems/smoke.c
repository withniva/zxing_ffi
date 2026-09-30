/*
 * Loads a libZXing at run time and decodes an 8-bit binary PGM (P5) through the C API, printing the text of each
 * barcode found. `rake gem:verify PLATFORM=x86_64-darwin` runs it under Rosetta on arm64 Macs, where no x86_64 Ruby
 * is available to load the gem itself.
 *
 *   cc -arch x86_64 -o smoke smoke.c && arch -x86_64 ./smoke libZXing.dylib image.pgm
 *
 * Exit status: 0 when at least one barcode was decoded, 1 otherwise, 2 on usage errors.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

#define ZXING_IMAGE_FORMAT_LUM 0x01000000

typedef const char *(*version_fn)(void);
typedef void *(*image_view_new_fn)(const unsigned char *, int, int, int, int, int);
typedef void *(*new_fn)(void);
typedef void (*delete_fn)(void *);
typedef void *(*read_fn)(const void *, const void *);
typedef int (*size_fn)(const void *);
typedef const void *(*at_fn)(const void *, int);
typedef char *(*text_fn)(const void *);
typedef char *(*error_fn)(void);

static void *symbol(void *lib, const char *name) {
  void *fn = dlsym(lib, name);
  if (!fn) {
    fprintf(stderr, "smoke: %s is not exported\n", name);
    exit(1);
  }
  return fn;
}

/* Next header integer of a PNM file, skipping whitespace and comments. */
static int header_int(FILE *f) {
  int c, value = 0, digits = 0;
  while ((c = fgetc(f)) != EOF) {
    if (c == '#') {
      while ((c = fgetc(f)) != EOF && c != '\n') {}
    } else if (c >= '0' && c <= '9') {
      value = value * 10 + (c - '0');
      digits++;
    } else if (digits) {
      return value; /* consumes exactly one whitespace byte after the number */
    }
  }
  return digits ? value : -1;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s LIBZXING IMAGE.pgm\n", argv[0]);
    return 2;
  }
  void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!lib) {
    fprintf(stderr, "smoke: %s\n", dlerror());
    return 1;
  }

  FILE *f = fopen(argv[2], "rb");
  if (!f || fgetc(f) != 'P' || fgetc(f) != '5') {
    fprintf(stderr, "smoke: %s is not a binary PGM\n", argv[2]);
    return 2;
  }
  int width = header_int(f), height = header_int(f), maxval = header_int(f);
  if (width <= 0 || height <= 0 || maxval != 255) {
    fprintf(stderr, "smoke: unsupported PGM header\n");
    return 2;
  }
  size_t size = (size_t)width * (size_t)height;
  unsigned char *pixels = malloc(size);
  if (!pixels || fread(pixels, 1, size, f) != size) {
    fprintf(stderr, "smoke: truncated PGM\n");
    return 2;
  }
  fclose(f);

  printf("zxing-cpp %s\n", ((version_fn)symbol(lib, "ZXing_Version"))());
  void *view = ((image_view_new_fn)symbol(lib, "ZXing_ImageView_new"))(pixels, width, height, ZXING_IMAGE_FORMAT_LUM, width, 1);
  void *options = ((new_fn)symbol(lib, "ZXing_ReaderOptions_new"))();
  void *barcodes = ((read_fn)symbol(lib, "ZXing_ReadBarcodes"))(view, options);
  if (!barcodes) {
    char *error = ((error_fn)symbol(lib, "ZXing_LastErrorMsg"))();
    fprintf(stderr, "smoke: ZXing_ReadBarcodes failed: %s\n", error ? error : "?");
    return 1;
  }
  int count = ((size_fn)symbol(lib, "ZXing_Barcodes_size"))(barcodes);
  for (int i = 0; i < count; i++) {
    const void *barcode = ((at_fn)symbol(lib, "ZXing_Barcodes_at"))(barcodes, i);
    char *text = ((text_fn)symbol(lib, "ZXing_Barcode_text"))(barcode);
    printf("%s\n", text ? text : "");
    ((delete_fn)symbol(lib, "ZXing_free"))(text);
  }
  ((delete_fn)symbol(lib, "ZXing_Barcodes_delete"))(barcodes);
  ((delete_fn)symbol(lib, "ZXing_ReaderOptions_delete"))(options);
  ((delete_fn)symbol(lib, "ZXing_ImageView_delete"))(view);
  free(pixels);
  return count > 0 ? 0 : 1;
}
