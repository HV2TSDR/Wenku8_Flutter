#include <mobi.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { WENKU_OK, WENKU_DRM, WENKU_INVALID, WENKU_TOO_LARGE, WENKU_IO };
static const size_t MAX_TEXT = 64u * 1024u * 1024u;
static const size_t MAX_OUTPUT = 512u * 1024u * 1024u;

static int save_parts(const MOBIPart *part, const char *directory,
                      const char *prefix, size_t *total, size_t *count) {
    for (; part; part = part->next) {
        if (!part->size) continue;
        if (++*count > 12000 || part->size > 40u * 1024u * 1024u ||
            part->size > MAX_OUTPUT - *total) return WENKU_TOO_LARGE;
        *total += part->size;
        const MOBIFileMeta meta = mobi_get_filemeta_by_type(part->type);
        char path[4096];
        const int length = part->type == T_OPF
            ? snprintf(path, sizeof(path), "%s/content.opf", directory)
            : snprintf(path, sizeof(path), "%s/%s%05zu.%s", directory, prefix,
                       part->uid, meta.extension);
        if (length < 0 || (size_t)length >= sizeof(path) || !part->data) return WENKU_INVALID;
        FILE *file = fopen(path, "wb");
        if (!file) return WENKU_IO;
        const size_t written = fwrite(part->data, 1, part->size, file);
        const int closed = fclose(file);
        if (written != part->size || closed) return WENKU_IO;
    }
    return WENKU_OK;
}

/* Only reconstructed resources are exported. Encryption support is not built. */
int wenku_export_mobi(const char *input, const char *output_directory) {
    int result = WENKU_INVALID;
    MOBIData *book = mobi_init();
    MOBIRawml *raw = NULL;
    if (!book) return result;
    if (mobi_load_filename(book, input) != MOBI_SUCCESS) goto done;
    if (mobi_is_encrypted(book)) { result = WENKU_DRM; goto done; }
    const size_t maximum = mobi_get_text_maxsize(book);
    if (!maximum || maximum == MOBI_NOTSET) goto done;
    if (maximum > MAX_TEXT) { result = WENKU_TOO_LARGE; goto done; }
    raw = mobi_init_rawml(book);
    if (!raw || mobi_parse_rawml_opt(raw, book, true, false, true) != MOBI_SUCCESS ||
        !raw->markup) goto done;
    size_t total = 0, count = 0;
    result = save_parts(raw->markup, output_directory, "part", &total, &count);
    if (result == WENKU_OK && raw->flow)
        result = save_parts(raw->flow->next, output_directory, "flow", &total, &count);
    if (result == WENKU_OK)
        result = save_parts(raw->resources, output_directory, "resource", &total, &count);
done:
    if (raw) mobi_free_rawml(raw);
    mobi_free(book);
    return result;
}

#ifdef WENKU_MOBI_CLI
int main(int argc, char **argv) {
    return argc == 3 ? wenku_export_mobi(argv[1], argv[2]) : WENKU_INVALID;
}
#endif
