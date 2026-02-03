import 'dart:convert';

String generateCertificateQrPayload({
  required String certId,
  required String pdfHash,
}) {
  final payload = {
    "v": 1,
    "type": "CERT",
    "certId": certId,
    "hash": pdfHash,
    "issuer": "CertoSec",
    "ts": DateTime.now().millisecondsSinceEpoch,
  };

  return jsonEncode(payload);
}
