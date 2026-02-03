import 'package:cloud_functions/cloud_functions.dart';

class BlockchainService {
  static final _functions = FirebaseFunctions.instance;

  static Future<String> storeCertificate({
    required String certId,
    required String pdfHash,
  }) async {
    final callable = _functions.httpsCallable('storeCertificateOnBlockchain');

    final result = await callable.call({
      'certId': certId,
      'pdfHash': pdfHash,
    });

    return result.data['txHash'];
  }
}
