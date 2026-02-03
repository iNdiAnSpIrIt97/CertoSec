import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/blockchain_verify_service.dart';

class QrVerifyPage extends StatefulWidget {
  const QrVerifyPage({super.key});

  @override
  State<QrVerifyPage> createState() => _QrVerifyPageState();
}

class _QrVerifyPageState extends State<QrVerifyPage> {
  bool isScanning = true;
  bool isLoading = false;
  bool? isValid;
  String? scannedHash;
  String? error;

  late final MobileScannerController scannerController;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusManager.instance.primaryFocus?.unfocus();
    });

    scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
    );
  }

  @override
  void dispose() {
    scannerController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------
  // HANDLE QR RESULT (WITH DETAILED ERROR MESSAGES)
  // ------------------------------------------------------------
  Future<void> _onDetect(BarcodeCapture capture) async {
    if (!isScanning || capture.barcodes.isEmpty) return;

    final raw = capture.barcodes.first.rawValue;

    print("📱 Raw QR Data: $raw"); // ✅ Debug logging

    if (raw == null || raw.isEmpty) {
      print("❌ QR data is null or empty");
      return;
    }

    setState(() {
      isScanning = false;
      isLoading = true;
      error = null;
      isValid = null;
    });

    try {
      // Try to parse JSON
      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(raw);
        print("✅ Parsed payload: $payload");
      } catch (e) {
        // Not valid JSON - definitely not our certificate QR
        print("❌ Not valid JSON: $e");
        setState(() {
          error = "INVALID_QR";
          isValid = null;
        });
        setState(() => isLoading = false);
        return;
      }

      // Check version
      if (payload["v"] != 1) {
        print("❌ Invalid version: ${payload["v"]}");
        setState(() {
          error = "INVALID_QR";
          isValid = null;
        });
        setState(() => isLoading = false);
        return;
      }

      // Check for type field (support both "t" and "type")
      final type = payload["type"] ?? payload["t"];
      if (type != "CERT") {
        print("❌ Invalid type: $type");
        setState(() {
          error = "INVALID_QR";
          isValid = null;
        });
        setState(() => isLoading = false);
        return;
      }

      // Get certId (support both "id" and "certId")
      final String? certId = payload["certId"] ?? payload["id"];
      if (certId == null || certId.isEmpty) {
        print("❌ Missing certificate ID");
        setState(() {
          error = "INVALID_QR";
          isValid = null;
        });
        setState(() => isLoading = false);
        return;
      }

      // Get hash (support both "h" and "hash")
      final String? pdfHash = payload["hash"] ?? payload["h"];
      if (pdfHash == null || pdfHash.isEmpty) {
        print("❌ Missing certificate hash");
        setState(() {
          error = "INVALID_QR";
          isValid = null;
        });
        setState(() => isLoading = false);
        return;
      }

      print("🔵 Verifying - CertID: $certId");
      print("🔵 Verifying - Hash: $pdfHash");

      // Now verify on blockchain
      final valid = await BlockchainVerifyService.verifyCertificate(
        certId: certId,
        pdfHash: pdfHash,
      );

      print("🔵 Verification result: $valid");

      setState(() {
        isValid = valid;
        scannedHash = pdfHash;
        // If not valid, it's tampered (valid QR format but hash doesn't match blockchain)
        if (!valid) {
          error = "TAMPERED";
        }
      });
    } catch (e) {
      print("❌ Unexpected error: $e");
      print("Raw QR data: $raw");

      setState(() {
        error = "INVALID_QR";
        isValid = null;
      });
    }

    setState(() => isLoading = false);
  }

  // ------------------------------------------------------------
  // UI
  // ------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    FocusManager.instance.primaryFocus?.unfocus();

    // Web camera guard
    if (kIsWeb) {
      return Scaffold(
        appBar: AppBar(
          title: const Text("Verify Certificate"),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              "QR scanning is best supported on mobile devices.\n\n"
              "Please use the mobile app or enter the hash manually.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Verify Certificate (Blockchain)"),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // CAMERA VIEW
          if (isScanning)
            Expanded(
              flex: 4,
              child: MobileScanner(
                controller: scannerController,
                onDetect: _onDetect,
              ),
            ),

          // RESULT PANEL
          Expanded(
            flex: 3,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: _buildResult(),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // RESULT UI (WITH SPECIFIC ERROR MESSAGES)
  // ------------------------------------------------------------
  Widget _buildResult() {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Invalid QR Code (not a certificate QR at all)
    if (error == "INVALID_QR") {
      return _statusBox(
        icon: Icons.qr_code_scanner_rounded,
        color: Colors.orange,
        title: "INVALID QR CODE",
        subtitle: "This is not a valid certificate QR code.\n\n"
            "Please scan a QR code from an official CertoSec certificate.",
      );
    }

    // Tampered Certificate (valid QR format but hash doesn't match blockchain)
    if (error == "TAMPERED") {
      return _statusBox(
        icon: Icons.warning,
        color: Colors.red,
        title: "⚠️ CERTIFICATE TAMPERED",
        subtitle: "This certificate has been modified or forged!\n\n"
            "The hash does not match blockchain records.\n"
            "DO NOT ACCEPT THIS CERTIFICATE.",
      );
    }

    // Generic error
    if (error != null) {
      return _statusBox(
        icon: Icons.error,
        color: Colors.red,
        title: "VERIFICATION FAILED",
        subtitle: error!,
      );
    }

    // Valid certificate
    if (isValid == true) {
      return _statusBox(
        icon: Icons.verified,
        color: Colors.green,
        title: "✓ CERTIFICATE VALID",
        subtitle: "Verified on Polygon Blockchain\n\n"
            "This certificate is authentic and untampered.\n\n"
            "Hash: ${scannedHash?.substring(0, 16)}...",
      );
    }

    // Default scanning state
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: const [
        Icon(Icons.qr_code_scanner, size: 64, color: Colors.blue),
        SizedBox(height: 12),
        Text(
          "Scan the QR code on the certificate",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        SizedBox(height: 8),
        Text(
          "Position the QR code within the frame",
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _statusBox({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 80, color: color),
        const SizedBox(height: 16),
        Text(
          title,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: () {
            setState(() {
              isScanning = true;
              isValid = null;
              scannedHash = null;
              error = null;
            });
          },
          icon: const Icon(Icons.refresh),
          label: const Text("Scan Another"),
        ),
      ],
    );
  }
}
