import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pdf_render/pdf_render.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

import '../../services/blockchain_verify_service.dart';

class QrVerifyPage extends StatefulWidget {
  const QrVerifyPage({super.key});

  @override
  State<QrVerifyPage> createState() => _QrVerifyPageState();
}

class _QrVerifyPageState extends State<QrVerifyPage> {
  // ── mode: "scan" | "manual" | "upload" ──
  String mode = "scan";

  bool isScanning = true;
  bool isLoading = false;
  bool? isValid;
  String? scannedHash;
  String? error;

  // manual-entry controllers
  final certIdCtrl = TextEditingController();
  final hashCtrl = TextEditingController();

  // uploaded-PDF state
  Uint8List? _uploadedPdfBytes;
  bool _pdfPicked = false;

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
    certIdCtrl.dispose();
    hashCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------
  // RESET helper — clears every result state
  // ------------------------------------------------------------
  void _reset() {
    setState(() {
      isScanning = true;
      isLoading = false;
      isValid = null;
      scannedHash = null;
      error = null;
      _uploadedPdfBytes = null;
      _pdfPicked = false;
    });
  }

  // ------------------------------------------------------------
  // CORE VERIFY — shared by all three entry modes
  // Accepts a raw JSON string (from camera / QR extraction / manual)
  // ------------------------------------------------------------
  Future<void> _verifyPayload(String raw) async {
    if (raw.isEmpty) return;

    setState(() {
      isScanning = false;
      isLoading = true;
      error = null;
      isValid = null;
    });

    try {
      // ── parse JSON ──
      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(raw);
        print("✅ Parsed payload: $payload");
      } catch (e) {
        print("❌ Not valid JSON: $e");
        setState(() {
          error = "INVALID_QR";
          isLoading = false;
        });
        return;
      }

      // ── version check  (accept v=1 OR missing v for legacy) ──
      final version = payload["v"];
      if (version != null && version != 1) {
        print("❌ Invalid version: $version");
        setState(() {
          error = "INVALID_QR";
          isLoading = false;
        });
        return;
      }

      // ── type check  (accept "type" or "t") ──
      final type = payload["type"] ?? payload["t"];
      if (type != "CERT") {
        print("❌ Invalid type: $type");
        setState(() {
          error = "INVALID_QR";
          isLoading = false;
        });
        return;
      }

      // ── certId  (accept "certId" or "id") ──
      final String? certId = payload["certId"] ?? payload["id"];
      if (certId == null || certId.isEmpty) {
        print("❌ Missing certificate ID");
        setState(() {
          error = "INVALID_QR";
          isLoading = false;
        });
        return;
      }

      // ── hash  (accept "hash" or "h" or legacy "pdfHash") ──
      final String? pdfHash =
          payload["hash"] ?? payload["h"] ?? payload["pdfHash"];
      if (pdfHash == null || pdfHash.isEmpty) {
        print("❌ Missing certificate hash");
        setState(() {
          error = "INVALID_QR";
          isLoading = false;
        });
        return;
      }

      print("🔵 Verifying — CertID: $certId");
      print("🔵 Verifying — Hash:   $pdfHash");

      // ── call Firebase Cloud Function (just checks hash exists on-chain) ──
      final valid = await BlockchainVerifyService.verifyCertificate(
        certId: certId,
        pdfHash: pdfHash,
      );

      print("🔵 Verification result: $valid");

      setState(() {
        isValid = valid;
        scannedHash = pdfHash;
        if (!valid) error = "TAMPERED";
      });
    } catch (e) {
      print("❌ Unexpected error: $e");
      setState(() => error = "INVALID_QR");
    }

    setState(() => isLoading = false);
  }

  // ------------------------------------------------------------
  // CAMERA  →  _verifyPayload
  // ------------------------------------------------------------
  Future<void> _onDetect(BarcodeCapture capture) async {
    if (!isScanning || capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    print("📱 Raw QR Data: $raw");
    if (raw == null || raw.isEmpty) return;
    await _verifyPayload(raw);
  }

  // ------------------------------------------------------------
  // MANUAL entry  →  build a fake payload and call _verifyPayload
  // ------------------------------------------------------------
  Future<void> _verifyManual() async {
    final certId = certIdCtrl.text.trim();
    final hash = hashCtrl.text.trim();

    if (certId.isEmpty || hash.isEmpty) {
      setState(() => error = "MANUAL_EMPTY");
      return;
    }

    // Synthesise the same JSON structure the generator writes
    final payload = jsonEncode({
      "v": 1,
      "type": "CERT",
      "certId": certId,
      "hash": hash,
    });

    await _verifyPayload(payload);
  }

  // ------------------------------------------------------------
  // PDF UPLOAD  →  extract QR  →  _verifyPayload
  // ------------------------------------------------------------
  Future<void> _pickAndVerifyPdf() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ["pdf"],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      setState(() {
        _uploadedPdfBytes = result.files.first.bytes;
        _pdfPicked = true;
        error = null;
        isValid = null;
      });
    } catch (e) {
      setState(() => error = "PICK_ERROR");
    }
  }

  Future<void> _verifyUploadedPdf() async {
    if (_uploadedPdfBytes == null) {
      setState(() => error = "NO_PDF");
      return;
    }

    setState(() {
      isLoading = true;
      isScanning = false;
      error = null;
      isValid = null;
    });

    try {
      final qrText = await _extractQRFromPdf(_uploadedPdfBytes!);
      if (qrText == null) {
        setState(() {
          error = "QR_NOT_FOUND";
          isLoading = false;
        });
        return;
      }
      print("📱 Extracted QR text from PDF: $qrText");
      await _verifyPayload(qrText);
    } catch (e) {
      print("❌ PDF QR extraction error: $e");
      setState(() {
        error = "QR_EXTRACT_FAIL";
        isLoading = false;
      });
    }
  }

  // ── actual QR extraction (fixed pixel-format conversion) ──
  Future<String?> _extractQRFromPdf(Uint8List pdfBytes) async {
    final doc = await PdfDocument.openData(pdfBytes);
    final page = await doc.getPage(1);

    // Render at 3× for reliable QR detection
    final pageImage = await page.render(
      width: page.width.toInt() * 3,
      height: page.height.toInt() * 3,
    );

    final uiImage = pageImage.imageIfAvailable;
    if (uiImage == null) return null;

    final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return null;

    final pngBytes = byteData.buffer.asUint8List();
    final decoded = img.decodeImage(pngBytes);
    if (decoded == null) return null;

    // ── FIXED pixel conversion ──
    // img.Image stores pixels as RGBA bytes.  zxing2's RGBLuminanceSource
    // expects an Int32List where every int is 0xAARRGGBB.
    // We build that array manually instead of a broken cast.
    final width = decoded.width;
    final height = decoded.height;
    final rgbaBytes = decoded.getBytes(); // Uint8List, 4 bytes per pixel RGBA
    final argbInts = Int32List(width * height);

    for (int i = 0; i < argbInts.length; i++) {
      final base = i * 4;
      final r = rgbaBytes[base];
      final g = rgbaBytes[base + 1];
      final b = rgbaBytes[base + 2];
      final a = rgbaBytes[base + 3];
      argbInts[i] = (a << 24) | (r << 16) | (g << 8) | b;
    }

    final luminanceSource = RGBLuminanceSource(width, height, argbInts);
    final bitmap = BinaryBitmap(GlobalHistogramBinarizer(luminanceSource));
    final reader = QRCodeReader();

    try {
      final result = reader.decode(bitmap);
      return result.text;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------
  // UI
  // ------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    // Web guard — camera won't work, but manual + upload still can
    if (kIsWeb && mode == "scan") {
      // auto-switch to manual on web
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mode == "scan") setState(() => mode = "manual");
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Verify Certificate"),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // ── MODE TABS ──
          _modeTabs(),

          // ── CONTENT per mode ──
          Expanded(
            child: mode == "scan" ? _scanView() : _inputView(),
          ),
        ],
      ),
    );
  }

  // ── three-way tab bar ──
  Widget _modeTabs() {
    final tabs = [
      {"key": "scan", "icon": Icons.qr_code_scanner, "label": "Scan QR"},
      {"key": "manual", "icon": Icons.vpn_key, "label": "Enter ID"},
      {"key": "upload", "icon": Icons.upload_file, "label": "Upload PDF"},
    ];

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: tabs
            .map((t) => Expanded(
                  child: _modeChip(t["key"] as String, t["icon"] as IconData,
                      t["label"] as String),
                ))
            .toList(),
      ),
    );
  }

  Widget _modeChip(String key, IconData icon, String label) {
    final selected = mode == key;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: () => setState(() {
          mode = key;
          _reset();
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? Colors.indigo : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  color: selected ? Colors.white : Colors.grey[700], size: 18),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.grey[700],
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    fontSize: 13,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  // ── camera scan layout ──
  Widget _scanView() {
    return Column(
      children: [
        if (isScanning)
          Expanded(
            flex: 4,
            child: MobileScanner(
              controller: scannerController,
              onDetect: _onDetect,
            ),
          ),
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
    );
  }

  // ── manual / upload layout ──
  Widget _inputView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ────────── MANUAL ENTRY ──────────
          if (mode == "manual") ...[
            Text("Certificate ID",
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[800])),
            const SizedBox(height: 6),
            TextField(
              controller: certIdCtrl,
              decoration: InputDecoration(
                hintText: "e.g. 1738051200000_ARY128",
                prefixIcon: const Icon(Icons.badge),
                filled: true,
                fillColor: Colors.grey.shade50,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 16),
            Text("PDF Hash (SHA-256)",
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[800])),
            const SizedBox(height: 6),
            TextField(
              controller: hashCtrl,
              decoration: InputDecoration(
                hintText: "64-character hex hash",
                prefixIcon: const Icon(Icons.lock),
                filled: true,
                fillColor: Colors.grey.shade50,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: isLoading ? null : _verifyManual,
                icon: const Icon(Icons.search),
                label: const Text("Verify"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],

          // ────────── PDF UPLOAD ──────────
          if (mode == "upload") ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: _pdfPicked
                        ? Colors.green.shade300
                        : Colors.grey.shade300,
                    width: 2),
              ),
              child: Column(
                children: [
                  Icon(Icons.picture_as_pdf,
                      size: 48,
                      color: _pdfPicked ? Colors.green : Colors.grey[400]),
                  const SizedBox(height: 10),
                  Text(
                    _pdfPicked ? "PDF selected ✓" : "No file selected",
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: _pdfPicked ? Colors.green : Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 14),
                  ElevatedButton.icon(
                    onPressed: _pickAndVerifyPdf,
                    icon: const Icon(Icons.folder_open),
                    label: const Text("Choose PDF"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.indigo,
                      side: const BorderSide(color: Colors.indigo),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed:
                    (isLoading || !_pdfPicked) ? null : _verifyUploadedPdf,
                icon: const Icon(Icons.verified),
                label: const Text("Verify PDF"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],

          // ── shared result panel ──
          const SizedBox(height: 24),
          if (isLoading || isValid != null || error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(20),
              ),
              child: _buildResult(),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // RESULT PANEL  (shared across all modes)
  // ------------------------------------------------------------
  Widget _buildResult() {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // ── error states ──
    if (error == "INVALID_QR") {
      return _statusBox(
        icon: Icons.qr_code_scanner_rounded,
        color: Colors.orange,
        title: "INVALID QR CODE",
        subtitle:
            "This is not a valid certificate QR code.\n\nPlease use a QR code from an official CertoSec certificate.",
      );
    }

    if (error == "TAMPERED") {
      return _statusBox(
        icon: Icons.warning,
        color: Colors.red,
        title: "⚠️ CERTIFICATE TAMPERED",
        subtitle:
            "This certificate has been modified or forged!\n\nThe hash does not match blockchain records.\nDO NOT ACCEPT THIS CERTIFICATE.",
      );
    }

    if (error == "MANUAL_EMPTY") {
      return _statusBox(
        icon: Icons.info,
        color: Colors.blue,
        title: "Fields Required",
        subtitle: "Please fill in both Certificate ID and PDF Hash.",
      );
    }

    if (error == "NO_PDF") {
      return _statusBox(
        icon: Icons.info,
        color: Colors.blue,
        title: "No PDF Selected",
        subtitle: "Please pick a certificate PDF first.",
      );
    }

    if (error == "QR_NOT_FOUND") {
      return _statusBox(
        icon: Icons.broken_image,
        color: Colors.orange,
        title: "QR NOT FOUND",
        subtitle:
            "Could not detect a QR code in this PDF.\nMake sure it is an official CertoSec certificate.",
      );
    }

    if (error == "QR_EXTRACT_FAIL") {
      return _statusBox(
        icon: Icons.error,
        color: Colors.red,
        title: "EXTRACTION FAILED",
        subtitle: "An error occurred while reading the PDF.\nPlease try again.",
      );
    }

    if (error == "PICK_ERROR") {
      return _statusBox(
        icon: Icons.error,
        color: Colors.red,
        title: "FILE ERROR",
        subtitle: "Could not open the selected file.",
      );
    }

    if (error != null) {
      return _statusBox(
        icon: Icons.error,
        color: Colors.red,
        title: "VERIFICATION FAILED",
        subtitle: error!,
      );
    }

    // ── success ──
    if (isValid == true) {
      return _statusBox(
        icon: Icons.verified,
        color: Colors.green,
        title: "✓ CERTIFICATE VALID",
        subtitle:
            "Verified on Blockchain\n\nThis certificate is authentic and untampered.\n\nHash: ${scannedHash?.substring(0, 16)}...",
      );
    }

    // ── idle / waiting ──
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: const [
        Icon(Icons.qr_code_scanner, size: 64, color: Colors.blue),
        SizedBox(height: 12),
        Text(
          "Scan, enter, or upload a certificate to verify",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          textAlign: TextAlign.center,
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
          onPressed: _reset,
          icon: const Icon(Icons.refresh),
          label: const Text("Try Again"),
        ),
      ],
    );
  }
}
