import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;
void registerAppLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Wenku8 Flutter',
    ], await rootBundle.loadString('assets/licenses/GPL-3.0.txt'));
    yield LicenseEntryWithLineBreaks(const [
      'Source Han Serif CN · Adobe',
    ], await rootBundle.loadString('assets/fonts/OFL-SourceHanSerif.txt'));
    yield LicenseEntryWithLineBreaks(const [
      'edge-tts protocol · rany',
    ], await rootBundle.loadString('assets/licenses/edge-tts.txt'));
    yield LicenseEntryWithLineBreaks(const [
      'libmobi · Bartek Fabiszewski',
    ], await rootBundle.loadString('assets/licenses/libmobi.txt'));
    for (final item in const {
      'jsoup · Jonathan Hedley': 'jsoup',
      'commonmark-java · Atlassian': 'commonmark',
      'PDFBox Android · Apache Software Foundation / Tom Roush': 'pdfbox',
      'PDFBox / FontBox notices': 'pdfbox-notice',
      'Bouncy Castle': 'bouncycastle',
      'OpenJDK desugaring · Oracle / Google': 'desugar-jdk',
      'OpenCC dictionaries · BYVoid and contributors': 'opencc',
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        item.key,
      ], await rootBundle.loadString('assets/licenses/${item.value}.txt'));
    }
  });
}
