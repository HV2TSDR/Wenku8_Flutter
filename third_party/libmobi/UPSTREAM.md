# libmobi

- Upstream: https://github.com/bfabiszewski/libmobi
- Version: v0.12
- License: LGPL-3.0-or-later; see COPYING and source headers.
- Upstream sources are unchanged. Wenku8's build configuration and bounded resource exporter are in `android/app/src/main/cpp/`.

The application dynamically links the shared library, disables encryption support,
and converts unencrypted MOBI/KF8 resources into a local EPUB during import. Source,
build configuration and the original license accompany the project.

The normal Android build uses CMake/NDK to produce `libmobi.so` and `libwenku_mobi.so`.
The same C exporter can be built on a desktop for the test corpus:

```
cmake -S android/app/src/main/cpp -B build/mobi-host -DCMAKE_BUILD_TYPE=Release
cmake --build build/mobi-host --target wenku_mobi
```

`BookArchiveImportTest.realMobiFixturesConvertThroughTheProductionPackager` accepts
`WENKU_MOBI_HOST` (absolute exporter executable), `WENKU_MOBI_SAMPLES` (absolute
`third_party/libmobi/tests/samples` directory) and `WENKU_MOBI_EPUBS` (output directory).
It converts the upstream samples through the actual Kotlin packager. Then run
`flutter test --dart-define=MOBI_EPUB_FIXTURES=<absolute output directory> test/mobi_import_test.dart`
to validate the resulting metadata, chapters, text and inline images.
