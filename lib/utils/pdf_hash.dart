import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Generates SHA-256 hash from PDF bytes
String generatePdfHash(Uint8List pdfBytes) {
  final digest = sha256.convert(pdfBytes);
  return digest.toString(); // 64-character hex string
}
