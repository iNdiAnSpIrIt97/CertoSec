import 'dart:convert';

class CertificateQrPayload {
  final int version;
  final String certificateId;
  final String pdfHash;
  final String blockchainTx;
  final String network;
  final String issuer;
  final int timestamp;

  CertificateQrPayload({
    required this.version,
    required this.certificateId,
    required this.pdfHash,
    required this.blockchainTx,
    required this.network,
    required this.issuer,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        "v": version,
        "certId": certificateId,
        "hash": pdfHash,
        "tx": blockchainTx,
        "net": network,
        "issuer": issuer,
        "ts": timestamp,
      };

  /// Compact JSON → better QR scan reliability
  String toCompactJson() => jsonEncode(toJson());
}
