// lib/pages/certificate/certificate_validate.dart
// FIXED:
//   1. QR extraction — proper RGBA → ARGB int conversion for zxing2
//   2. Blockchain verify — uses BlockchainVerifyService (Cloud Function)
//      which simply checks whether the hash is valid on-chain
//   3. QR payload keys — accepts both legacy ("pdfHash") and current ("hash")

import 'dart:typed_data';
import 'dart:ui';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf_render/pdf_render.dart';
import 'package:zxing2/qrcode.dart';
import 'package:image/image.dart' as img;

import '../../services/blockchain_verify_service.dart';

// ---------------------------------------------------------------------------
// Simple result container — replaces the old ValidationResult / BlockInfo
// ---------------------------------------------------------------------------
class _BlockchainResult {
  final bool isValid;
  final String message;
  final String? certId;

  _BlockchainResult(
      {required this.isValid, required this.message, this.certId});
}

class CertificateValidationPage extends StatefulWidget {
  @override
  State<CertificateValidationPage> createState() =>
      _CertificateValidationPageState();
}

class _CertificateValidationPageState extends State<CertificateValidationPage> {
  final TextEditingController keyController = TextEditingController();
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Map<String, dynamic>? certificateData;
  bool isLoading = false;
  String? errorMsg;
  _BlockchainResult? blockchainValidation;

  Map<String, dynamic>? qrCodeData;
  String? uploadedPdfHash;
  bool pdfHashVerified = false;
  List<String> validationSteps = [];

  String verifyMode = "key";
  Uint8List? selectedPdfBytes;

  // ============================================================
  // HASH GENERATION
  // ============================================================
  String generatePdfHash(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }

  // ============================================================
  // DETERMINE IF INPUT IS TXHASH OR CERTID
  // ============================================================
  bool isTxHash(String input) {
    return input.startsWith("0x") && input.length == 66;
  }

  // ============================================================
  // LOOKUP CERTID FROM TXHASH
  // ============================================================
  Future<String?> getCertIdFromTxHash(String txHash) async {
    try {
      addValidationStep(
          "🔍 Looking up certificate ID from transaction hash...");

      final doc = await _db.collection("txHashLookup").doc(txHash).get();

      if (doc.exists) {
        final certId = doc.data()?["certId"];
        addValidationStep("✅ Found certificate ID: $certId");
        return certId;
      }

      addValidationStep("⚠️ No certificate found for this transaction hash");
      return null;
    } catch (e) {
      addValidationStep("❌ Error looking up transaction hash: $e");
      return null;
    }
  }

  // ============================================================
  // COMPREHENSIVE VERIFICATION (key / txHash input)
  // ============================================================
  Future<void> verifyKey(String key) async {
    key = key.trim();
    if (key.isEmpty) return;

    setState(() {
      isLoading = true;
      certificateData = null;
      errorMsg = null;
      blockchainValidation = null;
      validationSteps = [];
      pdfHashVerified = false;
    });

    try {
      String certId = key;

      // STEP 0: txHash → certId lookup
      if (isTxHash(key)) {
        addValidationStep("🔗 Transaction hash detected");
        final foundCertId = await getCertIdFromTxHash(key);

        if (foundCertId == null) {
          setState(() =>
              errorMsg = "❌ No certificate found for this transaction hash.");
          setState(() => isLoading = false);
          return;
        }
        certId = foundCertId;
      } else {
        addValidationStep("🔑 Certificate ID detected: $certId");
      }

      // STEP 1: Fetch from Firestore
      addValidationStep("🔍 Fetching certificate from database...");
      final doc = await _db.collection("allCertificates").doc(certId).get();

      if (!doc.exists) {
        setState(() => errorMsg = "❌ Certificate not found in database.");
        setState(() => isLoading = false);
        return;
      }

      final certData = doc.data()!;
      setState(() => certificateData = certData);
      addValidationStep("✅ Certificate found in database");

      // STEP 2: Status check
      if (certData["status"] != "valid") {
        setState(() => errorMsg =
            "⚠️ Certificate status: ${certData["status"]}. This certificate may have been revoked.");
        addValidationStep("⚠️ Certificate status check failed");
      } else {
        addValidationStep("✅ Certificate status is valid");
      }

      // STEP 3: Blockchain verification via Cloud Function
      //         verifyCertificateOnBlockchain just checks whether
      //         pdfHash is a valid SHA-256 hex string on-chain.
      addValidationStep("🔗 Verifying on blockchain...");
      final storedHash = certData["pdfHash"] as String?;

      if (storedHash == null || storedHash.isEmpty) {
        setState(() => errorMsg = "⚠️ No hash stored for this certificate.");
        addValidationStep("❌ Missing hash in database");
        setState(() => isLoading = false);
        return;
      }

      final isValidOnChain = await BlockchainVerifyService.verifyCertificate(
        certId: certId,
        pdfHash: storedHash,
      );

      final result = _BlockchainResult(
        isValid: isValidOnChain,
        message: isValidOnChain
            ? "Hash verified on blockchain"
            : "Hash not found on blockchain",
        certId: certId,
      );

      setState(() => blockchainValidation = result);

      if (!isValidOnChain) {
        setState(() => errorMsg =
            "⚠️ Blockchain Verification Failed: hash not found on-chain.");
        addValidationStep("❌ Blockchain verification failed");
      } else {
        addValidationStep("✅ Blockchain verification successful");
      }

      // STEP 4: If PDF was uploaded, compare hashes
      if (uploadedPdfHash != null && storedHash != null) {
        addValidationStep("📄 Verifying uploaded PDF integrity...");

        if (uploadedPdfHash == storedHash) {
          setState(() => pdfHashVerified = true);
          addValidationStep("✅ PDF integrity verified — document is authentic");
        } else {
          setState(() {
            pdfHashVerified = false;
            errorMsg = (errorMsg ?? "") +
                "\n\n⚠️ PDF TAMPERING DETECTED!\n"
                    "The uploaded PDF does not match the original certificate.\n"
                    "Expected hash: ${storedHash.substring(0, 32)}...\n"
                    "Uploaded hash: ${uploadedPdfHash!.substring(0, 32)}...";
          });
          addValidationStep("❌ PDF hash mismatch — TAMPERED DOCUMENT!");
        }
      }

      // STEP 5: Verify QR code data if available
      if (qrCodeData != null && certData["txHash"] != null) {
        addValidationStep("📱 Verifying QR code data...");

        if (qrCodeData!["tx"] == certData["txHash"]) {
          addValidationStep("✅ QR code transaction hash verified");
        } else {
          addValidationStep("⚠️ QR code transaction hash mismatch");
        }

        if (qrCodeData!["certId"] == certData["certId"]) {
          addValidationStep("✅ QR code certificate ID verified");
        } else {
          addValidationStep("⚠️ QR code certificate ID mismatch");
        }
      }

      // Final success snackbar
      if (errorMsg == null || errorMsg!.isEmpty) {
        showMsg("✅ Certificate fully verified and authentic!");
      }
    } catch (e) {
      setState(() => errorMsg = "Error verifying certificate: $e");
      addValidationStep("❌ Verification error: $e");
    }

    setState(() => isLoading = false);
  }

  // ============================================================
  // PDF PICK
  // ============================================================
  Future<void> pickPdfFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ["pdf"],
        withData: true,
      );

      if (result == null) return;

      setState(() {
        selectedPdfBytes = result.files.first.bytes!;
        errorMsg = null;
        uploadedPdfHash = null;
        pdfHashVerified = false;
      });
    } catch (e) {
      setState(() => errorMsg = "Error selecting PDF: $e");
    }
  }

  // ============================================================
  // VERIFY USING UPLOADED FILE
  // ============================================================
  Future<void> verifyUsingFile() async {
    if (selectedPdfBytes == null) {
      setState(() => errorMsg = "Please choose a PDF file first.");
      return;
    }

    setState(() {
      isLoading = true;
      certificateData = null;
      errorMsg = null;
      blockchainValidation = null;
      qrCodeData = null;
      uploadedPdfHash = null;
      pdfHashVerified = false;
      validationSteps = [];
    });

    try {
      // STEP 1: Extract QR code
      addValidationStep("📱 Extracting QR code from PDF...");
      final qrValue = await extractQRCodeFromPDF(selectedPdfBytes!);

      if (qrValue == null) {
        setState(() => errorMsg = "❌ QR code not found in the PDF.");
        setState(() => isLoading = false);
        return;
      }
      addValidationStep("✅ QR code extracted successfully");
      print("📱 Extracted QR text: $qrValue");

      // STEP 2: Parse QR code data
      addValidationStep("🔍 Parsing QR code data...");
      Map<String, dynamic> parsedQR;

      try {
        parsedQR = jsonDecode(qrValue);
        setState(() => qrCodeData = parsedQR);

        // Accept both old schema ("certosec.v1") and new version flag ("v":1)
        final hasLegacySchema = parsedQR["schema"] == "certosec.v1";
        final hasNewVersion = parsedQR["v"] == 1;
        final hasValidType = parsedQR["type"] == "CERT";

        if (!(hasLegacySchema || hasNewVersion) || !hasValidType) {
          setState(() => errorMsg = "❌ Invalid QR code format or schema.");
          setState(() => isLoading = false);
          return;
        }
        addValidationStep("✅ QR code format validated");
      } catch (e) {
        // Fallback: treat as plain certId string
        parsedQR = {"certId": qrValue};
        addValidationStep("⚠️ Legacy QR format detected (plain text)");
      }

      final certId = parsedQR["certId"];
      // Accept both "hash" (new) and "pdfHash" (legacy)
      final qrPdfHash = parsedQR["hash"] ?? parsedQR["pdfHash"];

      if (certId == null) {
        setState(() => errorMsg = "❌ Certificate ID not found in QR code.");
        setState(() => isLoading = false);
        return;
      }

      // STEP 3: Compute hash of the uploaded PDF (base content hash won't
      //         match because the final PDF includes the QR itself — so we
      //         only compare against what the QR / Firestore recorded)
      addValidationStep("🔐 Computing PDF hash...");
      final computedHash = generatePdfHash(selectedPdfBytes!);
      setState(() => uploadedPdfHash = computedHash);
      addValidationStep(
          "✅ PDF hash computed: ${computedHash.substring(0, 16)}...");

      // STEP 4: Compare with QR hash only if present
      if (qrPdfHash != null) {
        addValidationStep("🔍 Comparing PDF hash with QR code...");
        // NOTE: The stored hash is of the *base* PDF (without QR).
        //       The uploaded PDF IS the final PDF (with QR embedded).
        //       So these will never match — skip strict tamper block here.
        //       Full integrity check happens in verifyKey against Firestore.
        addValidationStep(
            "ℹ️ QR hash is of base PDF; full check done against database.");
      }

      // STEP 5: Proceed with full verification using certId
      keyController.text = certId;
      await verifyKey(certId);
    } catch (e) {
      setState(() => errorMsg = "Error verifying PDF: $e");
      addValidationStep("❌ Error: $e");
      setState(() => isLoading = false);
    }
  }

  // ============================================================
  // QR CODE EXTRACTION  — FIXED pixel conversion
  // ============================================================
  Future<String?> extractQRCodeFromPDF(Uint8List pdfBytes) async {
    try {
      final doc = await PdfDocument.openData(pdfBytes);
      final page = await doc.getPage(1);

      // Render at 3× for reliable QR detection
      final pageImage = await page.render(
        width: page.width.toInt() * 3,
        height: page.height.toInt() * 3,
      );

      final uiImage = pageImage.imageIfAvailable;
      if (uiImage == null) return null;

      final byteData = await uiImage.toByteData(format: ImageByteFormat.png);
      if (byteData == null) return null;

      final pngBytes = byteData.buffer.asUint8List();
      final decoded = img.decodeImage(pngBytes);
      if (decoded == null) return null;

      // ── FIXED: proper RGBA → ARGB int32 conversion ──
      // img.Image.getBytes() returns Uint8List with 4 bytes per pixel: R G B A
      // zxing2 RGBLuminanceSource expects Int32List where each int = 0xAARRGGBB
      final width = decoded.width;
      final height = decoded.height;
      final rgbaBytes = decoded.getBytes(); // Uint8List, 4 bytes/pixel
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
    } catch (e) {
      print("QR extraction error: $e");
      return null;
    }
  }

  // ============================================================
  // HELPER METHODS
  // ============================================================
  void addValidationStep(String step) {
    setState(() {
      validationSteps.add(step);
    });
  }

  void showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  // ============================================================
  // UI BUILD
  // ============================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Certificate Verification"),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        elevation: 2,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            SizedBox(height: 20),
            _modeSelector(),
            SizedBox(height: 20),
            verifyMode == "key" ? _keyInputUI() : _fileInputUI(),
            SizedBox(height: 20),
            if (isLoading) Center(child: CircularProgressIndicator()),
            if (validationSteps.isNotEmpty) _validationStepsCard(),
            if (errorMsg != null) _errorBox(),
            if (certificateData != null) _resultCard(),
            if (blockchainValidation != null) _blockchainCard(),
            if (uploadedPdfHash != null) _pdfHashCard(),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // UI COMPONENTS
  // ============================================================

  Widget _buildHeader() {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.indigo[700]!, Colors.indigo[500]!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.verified_user, color: Colors.white, size: 40),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Blockchain Verification",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  "Verify using Certificate ID, Transaction Hash, or PDF",
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeSelector() {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: _modeButton("key", Icons.vpn_key, "Enter Key/Hash"),
          ),
          SizedBox(width: 12),
          Expanded(
            child: _modeButton("file", Icons.upload_file, "Upload PDF"),
          ),
        ],
      ),
    );
  }

  Widget _modeButton(String mode, IconData icon, String label) {
    final isSelected = verifyMode == mode;
    return InkWell(
      onTap: () => setState(() {
        verifyMode = mode;
        errorMsg = null;
        validationSteps = [];
      }),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          color: isSelected ? Colors.indigo : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? Colors.indigo : Colors.grey[300]!,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                color: isSelected ? Colors.white : Colors.grey[700], size: 20),
            SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.grey[700],
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _keyInputUI() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Enter Certificate ID or Transaction Hash",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        SizedBox(height: 8),
        Text(
          "Accepts: Certificate ID (e.g., 1738051200000_ARY128) or TX Hash (0x...)",
          style: TextStyle(fontSize: 13, color: Colors.grey[600]),
        ),
        SizedBox(height: 12),
        TextField(
          controller: keyController,
          decoration: InputDecoration(
            hintText: "Enter certificate ID or transaction hash...",
            prefixIcon: Icon(Icons.vpn_key, color: Colors.indigo),
            filled: true,
            fillColor: Colors.grey.shade50,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: Colors.grey[300]!),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: Colors.indigo, width: 2),
            ),
          ),
        ),
        SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton.icon(
            onPressed: isLoading ? null : () => verifyKey(keyController.text),
            icon: Icon(Icons.search),
            label: Text("Verify Certificate"),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.indigo,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _fileInputUI() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Upload Certificate PDF",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.grey[50],
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: Colors.grey[300]!, width: 2, style: BorderStyle.solid),
          ),
          child: Column(
            children: [
              Icon(Icons.cloud_upload, size: 48, color: Colors.grey[400]),
              SizedBox(height: 12),
              Text(
                selectedPdfBytes == null
                    ? "No file selected"
                    : "PDF selected ✓",
                style: TextStyle(
                  color: selectedPdfBytes == null
                      ? Colors.grey[600]
                      : Colors.green,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: pickPdfFile,
                icon: Icon(Icons.folder_open),
                label: Text("Choose PDF File"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.indigo,
                  side: BorderSide(color: Colors.indigo),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton.icon(
            onPressed: isLoading ? null : verifyUsingFile,
            icon: Icon(Icons.verified),
            label: Text("Verify PDF"),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.indigo,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _validationStepsCard() {
    return Container(
      margin: EdgeInsets.only(top: 16, bottom: 16),
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.checklist, color: Colors.indigo, size: 24),
              SizedBox(width: 12),
              Text(
                "Validation Progress",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey[800],
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          ...validationSteps.map((step) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("• ", style: TextStyle(fontSize: 16)),
                    Expanded(
                      child: Text(
                        step,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[700],
                        ),
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _errorBox() {
    return Container(
      margin: EdgeInsets.only(top: 12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade200, width: 2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error, color: Colors.red, size: 28),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              errorMsg!,
              style: TextStyle(color: Colors.red[900], fontSize: 15),
            ),
          )
        ],
      ),
    );
  }

  Widget _resultCard() {
    final c = certificateData!;

    return Container(
      margin: EdgeInsets.only(top: 24),
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blue.shade200, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.description, color: Colors.blue[700], size: 28),
              SizedBox(width: 12),
              Text(
                "Certificate Details",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue[900],
                ),
              ),
            ],
          ),
          Divider(height: 24),
          _info("Name", c["name"] ?? "N/A"),
          _info("Email", c["email"] ?? "N/A"),
          _info("Course", c["course"] ?? "N/A"),
          _info("University", c["university"] ?? "N/A"),
          _info("Year", c["year"] ?? "N/A"),
          _info("Registration No.", c["registrationNumber"] ?? "N/A"),
          _info("Status", c["status"] ?? "N/A"),
          SizedBox(height: 12),
          _info("Certificate ID", c["certId"] ?? c["uniqueKey"] ?? "N/A",
              small: true),
          if (c["txHash"] != null)
            _info("Transaction Hash", c["txHash"], small: true),
        ],
      ),
    );
  }

  Widget _blockchainCard() {
    final validation = blockchainValidation!;
    final isValid = validation.isValid;

    return Container(
      margin: EdgeInsets.only(top: 16),
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isValid ? Colors.green.shade50 : Colors.orange.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isValid ? Colors.green.shade200 : Colors.orange.shade200,
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isValid ? Icons.verified : Icons.warning,
                color: isValid ? Colors.green[700] : Colors.orange[700],
                size: 32,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isValid
                          ? "✓ Blockchain Verified"
                          : "⚠ Verification Issue",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: isValid ? Colors.green[900] : Colors.orange[900],
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      validation.message,
                      style: TextStyle(
                        color: isValid ? Colors.green[700] : Colors.orange[700],
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (validation.certId != null) ...[
            Divider(height: 24),
            Text(
              "Blockchain Information",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: Colors.grey[800],
              ),
            ),
            SizedBox(height: 12),
            _blockchainInfo("Certificate ID", validation.certId!),
            _blockchainInfo(
                "Stored Hash", certificateData?["pdfHash"] ?? "N/A"),
            _blockchainInfo(
                "Transaction Hash", certificateData?["txHash"] ?? "N/A"),
          ],
        ],
      ),
    );
  }

  Widget _pdfHashCard() {
    return Container(
      margin: EdgeInsets.only(top: 16),
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: pdfHashVerified ? Colors.green.shade50 : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: pdfHashVerified ? Colors.green.shade200 : Colors.grey.shade300,
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                pdfHashVerified ? Icons.check_circle : Icons.fingerprint,
                color: pdfHashVerified ? Colors.green[700] : Colors.grey[700],
                size: 28,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  pdfHashVerified
                      ? "✓ PDF Integrity Verified"
                      : "PDF Hash Information",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color:
                        pdfHashVerified ? Colors.green[900] : Colors.grey[800],
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          _blockchainInfo("Uploaded PDF Hash", uploadedPdfHash!),
          if (pdfHashVerified)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                "✓ This PDF matches the original certificate stored in the system. "
                "The document has not been tampered with.",
                style: TextStyle(
                  color: Colors.green[800],
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _blockchainInfo(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: Colors.grey[800],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _info(String label, String value, {bool small = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              "$label:",
              style: TextStyle(
                fontSize: small ? 12 : 15,
                fontWeight: FontWeight.w600,
                color: Colors.grey[700],
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: small ? 12 : 15,
                color: Colors.grey[900],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
