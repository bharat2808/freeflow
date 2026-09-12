#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#if __has_include(<whisper.h>)
#include <dlfcn.h>
#include <whisper.h>

typedef struct {
    void *library;
    struct whisper_context *context;
    char *language;
} ff_whisper_session;

typedef struct whisper_context *(*ff_init_fn)(const char *, struct whisper_context_params);
typedef struct whisper_context_params (*ff_context_params_fn)(void);
typedef struct whisper_full_params (*ff_full_params_fn)(enum whisper_sampling_strategy);
typedef int (*ff_full_fn)(struct whisper_context *, struct whisper_full_params, const float *, int);
typedef int (*ff_segment_count_fn)(struct whisper_context *);
typedef const char *(*ff_segment_text_fn)(struct whisper_context *, int);
typedef void (*ff_free_fn)(struct whisper_context *);

static void *ff_open_library(void) {
    static const char *paths[] = {
        "/opt/homebrew/lib/libwhisper.dylib",
        "/usr/local/lib/libwhisper.dylib",
        "libwhisper.dylib",
        NULL
    };
    for (size_t i = 0; paths[i] != NULL; i++) {
        void *library = dlopen(paths[i], RTLD_LOCAL | RTLD_NOW);
        if (library != NULL) return library;
    }
    return NULL;
}

static void *ff_symbol(void *library, const char *name) {
    return dlsym(library, name);
}

void *ff_whisper_create(const char *model_path, const char *language) {
    void *library = ff_open_library();
    if (library == NULL) return NULL;

    ff_init_fn init = (ff_init_fn)ff_symbol(library, "whisper_init_from_file_with_params");
    ff_context_params_fn context_params = (ff_context_params_fn)ff_symbol(library, "whisper_context_default_params");
    if (init == NULL || context_params == NULL) {
        dlclose(library);
        return NULL;
    }

    ff_whisper_session *session = calloc(1, sizeof(ff_whisper_session));
    if (session == NULL) {
        dlclose(library);
        return NULL;
    }
    session->library = library;
    if (language != NULL && language[0] != '\0') {
        session->language = strdup(language);
    }
    struct whisper_context_params params = context_params();
    session->context = init(model_path, params);
    if (session->context == NULL) {
        free(session->language);
        free(session);
        dlclose(library);
        return NULL;
    }
    return session;
}

int ff_whisper_transcribe(void *opaque, const float *samples, int sample_count, char *output, size_t output_capacity) {
    if (opaque == NULL || samples == NULL || sample_count <= 0 || output == NULL || output_capacity == 0) return -1;
    ff_whisper_session *session = (ff_whisper_session *)opaque;
    ff_full_params_fn default_params = (ff_full_params_fn)ff_symbol(session->library, "whisper_full_default_params");
    ff_full_fn full = (ff_full_fn)ff_symbol(session->library, "whisper_full");
    ff_segment_count_fn segment_count = (ff_segment_count_fn)ff_symbol(session->library, "whisper_full_n_segments");
    ff_segment_text_fn segment_text = (ff_segment_text_fn)ff_symbol(session->library, "whisper_full_get_segment_text");
    if (default_params == NULL || full == NULL || segment_count == NULL || segment_text == NULL) return -1;

    struct whisper_full_params params = default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = 4;
    params.no_context = true;
    params.no_timestamps = true;
    params.single_segment = false;
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.language = session->language;
    params.detect_language = session->language == NULL;

    if (full(session->context, params, samples, sample_count) != 0) return -1;

    size_t used = 0;
    output[0] = '\0';
    int count = segment_count(session->context);
    for (int i = 0; i < count; i++) {
        const char *text = segment_text(session->context, i);
        if (text == NULL || text[0] == '\0') continue;
        size_t length = strlen(text);
        if (used != 0 && used + 1 < output_capacity) output[used++] = ' ';
        if (used + length >= output_capacity) length = output_capacity - used - 1;
        memcpy(output + used, text, length);
        used += length;
        output[used] = '\0';
        if (used + 1 >= output_capacity) break;
    }
    return (int)used;
}

void ff_whisper_destroy(void *opaque) {
    if (opaque == NULL) return;
    ff_whisper_session *session = (ff_whisper_session *)opaque;
    ff_free_fn free_context = (ff_free_fn)ff_symbol(session->library, "whisper_free");
    if (free_context != NULL) free_context(session->context);
    free(session->language);
    void *library = session->library;
    free(session);
    if (library != NULL) dlclose(library);
}

#else

void *ff_whisper_create(const char *model_path, const char *language) {
    (void)model_path;
    (void)language;
    return NULL;
}

int ff_whisper_transcribe(void *session, const float *samples, int sample_count, char *output, size_t output_capacity) {
    (void)session;
    (void)samples;
    (void)sample_count;
    (void)output;
    (void)output_capacity;
    return -1;
}

void ff_whisper_destroy(void *session) {
    (void)session;
}

#endif
