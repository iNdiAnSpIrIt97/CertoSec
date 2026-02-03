import 'package:cloud_functions/cloud_functions.dart';

class BlockchainVerifyService {
  static Future<bool> verifyCertificate({
    required String certId,
    required String pdfHash,
  }) async {
    final callable = FirebaseFunctions.instance
        .httpsCallable("verifyCertificateOnBlockchain");

    final result = await callable.call({
      "certId": certId,
      "pdfHash": pdfHash,
    });

    return result.data["valid"] == true;
  }
}
