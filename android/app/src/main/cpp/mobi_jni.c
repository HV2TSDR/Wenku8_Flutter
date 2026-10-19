#include <jni.h>
int wenku_export_mobi(const char *input, const char *output_directory);

JNIEXPORT jint JNICALL
Java_org_mewx_wenku8_1flutter_MobiConverter_exportParts(
        JNIEnv *env, jobject owner, jstring input, jstring output) {
    (void)owner;
    const char *source = (*env)->GetStringUTFChars(env, input, NULL);
    if (!source) return 2;
    const char *destination = (*env)->GetStringUTFChars(env, output, NULL);
    if (!destination) {
        (*env)->ReleaseStringUTFChars(env, input, source);
        return 2;
    }
    const int result = wenku_export_mobi(source, destination);
    (*env)->ReleaseStringUTFChars(env, output, destination);
    (*env)->ReleaseStringUTFChars(env, input, source);
    return result;
}
