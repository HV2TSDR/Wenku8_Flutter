# PDFBox's JPX codec is an optional JCenter-only dependency. The importer
# rejects JPX images explicitly before decoding; other PDF filters stay live.
-dontwarn com.gemalto.jp2.JP2Decoder
-dontwarn com.gemalto.jp2.JP2Encoder
