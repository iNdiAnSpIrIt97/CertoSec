import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // kIsWeb
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/blockchain_service.dart';
import '../../utils/pdf_downloader.dart'; // for web download

class CertificateGeneratorPage extends StatefulWidget {
  const CertificateGeneratorPage({super.key});

  @override
  State<CertificateGeneratorPage> createState() =>
      _CertificateGeneratorPageState();
}

class _CertificateGeneratorPageState extends State<CertificateGeneratorPage> {
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final regController = TextEditingController();
  final yearController = TextEditingController();

  List<String> universityList = [];
  String? selectedUniversity;
  String? selectedCourse;

  bool isGenerating = false;
  bool isSaving = false;
  Uint8List? pdfBytes;

  // Track the current certificate's metadata
  String? _currentCertId;
  String? _currentTxHash;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final List<String> courses = [
    "Business Management",
    "Human Resource Management",
    "Marketing Management",
    "Operations Management",
    "Financial Management",
    "Logistics & Supply Chain Management"
  ];

  @override
  void initState() {
    super.initState();
    selectedCourse = courses.first;
    _loadUserUniversities();
  }

  void showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  bool validateForm() {
    if (nameController.text.isEmpty) return false;
    if (!emailController.text.contains("@")) return false;
    if (regController.text.length < 5) return false;
    if (selectedUniversity == null) return false;
    if (yearController.text.isEmpty) return false;
    return true;
  }

  Future<void> _loadUserUniversities() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await _firestore.collection("users").doc(user.uid).get();
    final list = (doc.data()?["university"] ?? []) as List;

    setState(() {
      universityList = list.map((e) => e.toString()).toList();
      selectedUniversity =
          universityList.isNotEmpty ? universityList.first : null;
    });
  }

  // ============================================================
  // HASH GENERATION
  // ============================================================
  String generatePdfHash(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }

  // ============================================================
  // BASE PDF (NO QR → FOR HASH)
  // ============================================================
  Future<Uint8List> _createBasePDF({
    required String name,
    required String course,
    required String university,
    required String year,
    required String reg,
  }) async {
    final pdf = pw.Document();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text(
              university.toUpperCase(),
              style: pw.TextStyle(
                fontSize: 24,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 30),
            pw.Text(
              "Certificate of Completion",
              style: pw.TextStyle(
                fontSize: 32,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 40),
            pw.Text("This is to certify that"),
            pw.SizedBox(height: 16),
            pw.Text(
              name,
              style: pw.TextStyle(
                fontSize: 36,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 20),
            pw.Text("has successfully completed"),
            pw.SizedBox(height: 12),
            pw.Text(
              course,
              style: pw.TextStyle(
                fontSize: 22,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 30),
            pw.Text("Academic Year: $year"),
            pw.Text("Registration No: $reg"),
          ],
        ),
      ),
    );

    return pdf.save();
  }

  // ============================================================
  // QR CODE GENERATION
  // ============================================================
  Future<Uint8List> _generateQRCode({
    required String certId,
    required String pdfHash,
    required String txHash,
  }) async {
    final payload = jsonEncode({
      "v": 1,
      "type": "CERT",
      "certId": certId,
      "hash": pdfHash,
      "tx": txHash,
      "issuer": "CertoSec",
    });

    print("QR Payload: $payload");

    final qrValidation = QrValidator.validate(
      data: payload,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.H,
    );

    if (qrValidation.status != QrValidationStatus.valid) {
      throw Exception("QR generation failed");
    }

    final painter = QrPainter.withQr(
      qr: qrValidation.qrCode!,
      color: Colors.black,
      gapless: true,
    );

    final image = await painter.toImage(400);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

    return byteData!.buffer.asUint8List();
  }

  // ============================================================
  // FINAL PDF WITH QR AND DESIGN
  // ============================================================
  Future<Uint8List> _createFinalPDF({
    required String certId,
    required String name,
    required String course,
    required String university,
    required String year,
    required String reg,
    required String pdfHash,
    required String txHash,
    required Uint8List qrBytes,
  }) async {
    final pdf = pw.Document();

    // Load logo - wrapped in try-catch for web compatibility
    pw.ImageProvider? logoImage;
    try {
      final logoBytes =
          await DefaultAssetBundle.of(context).load('assets/logo.png');
      logoImage = pw.MemoryImage(logoBytes.buffer.asUint8List());
    } catch (e) {
      print("⚠️ Logo not loaded: $e");
      // Continue without logo if it fails
    }

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (_) => pw.Stack(
          children: [
            // Border
            pw.Container(
              decoration: pw.BoxDecoration(
                border: pw.Border.all(width: 3),
              ),
            ),

            pw.Padding(
              padding: const pw.EdgeInsets.all(36),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  // Logo (if loaded)
                  if (logoImage != null) ...[
                    pw.Image(logoImage, width: 90),
                    pw.SizedBox(height: 16),
                  ],

                  pw.Text(
                    university.toUpperCase(),
                    style: pw.TextStyle(
                      fontSize: 22,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),

                  pw.SizedBox(height: 24),

                  pw.Text(
                    "Certificate of Completion",
                    style: pw.TextStyle(
                      fontSize: 32,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),

                  pw.SizedBox(height: 32),

                  pw.Text("This is to certify that"),
                  pw.SizedBox(height: 14),

                  pw.Text(
                    name,
                    style: pw.TextStyle(
                      fontSize: 36,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),

                  pw.SizedBox(height: 20),

                  pw.Text("has successfully completed"),

                  pw.SizedBox(height: 12),

                  pw.Text(
                    course,
                    style: pw.TextStyle(
                      fontSize: 22,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),

                  pw.SizedBox(height: 28),

                  pw.Text("Academic Year: $year"),
                  pw.Text("Registration No: $reg"),

                  pw.Spacer(),

                  // Signatures
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Column(
                        children: [
                          pw.Text(
                            "Irene Tracey",
                            style: pw.TextStyle(
                              fontSize: 18,
                              fontStyle: pw.FontStyle.italic,
                            ),
                          ),
                          pw.SizedBox(height: 4),
                          pw.Container(width: 140, height: 1),
                          pw.Text("Vice-Chancellor"),
                        ],
                      ),
                      pw.Column(
                        children: [
                          pw.Text(
                            "Gillian Aitken",
                            style: pw.TextStyle(
                              fontSize: 18,
                              fontStyle: pw.FontStyle.italic,
                            ),
                          ),
                          pw.SizedBox(height: 4),
                          pw.Container(width: 140, height: 1),
                          pw.Text("Registrar"),
                        ],
                      ),
                    ],
                  ),

                  pw.SizedBox(height: 20),
                ],
              ),
            ),

            // QR Code (bottom-right)
            pw.Positioned(
              right: 36,
              bottom: 130,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Image(
                    pw.MemoryImage(qrBytes),
                    width: 100,
                    height: 100,
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    "Scan to Verify",
                    style: pw.TextStyle(
                      fontSize: 8,
                      color: PdfColors.grey700,
                    ),
                  ),
                ],
              ),
            ),

            // Transaction Hash (below border)
            pw.Positioned(
              left: 0,
              right: 0,
              bottom: 6,
              child: pw.Center(
                child: pw.Text(
                  txHash,
                  style: pw.TextStyle(
                    fontSize: 7,
                    color: PdfColors.grey700,
                  ),
                ),
              ),
            ),

            // Certificate ID (top-right, small)
            pw.Positioned(
              right: 36,
              top: 36,
              child: pw.Text(
                "ID: $certId",
                style: pw.TextStyle(
                  fontSize: 8,
                  color: PdfColors.grey600,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return pdf.save();
  }

  // ============================================================
  // MAIN GENERATION FLOW
  // ============================================================
  Future<void> generateCertificate() async {
    if (!validateForm()) {
      showMsg("❌ Please fill all fields correctly");
      return;
    }

    setState(() => isGenerating = true);

    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final certId = "${timestamp}_${regController.text}";

      print("📝 Generating certificate: $certId");

      final basePdf = await _createBasePDF(
        name: nameController.text,
        course: selectedCourse!,
        university: selectedUniversity!,
        year: yearController.text,
        reg: regController.text,
      );

      final pdfHash = generatePdfHash(basePdf);
      print("🔐 PDF Hash: $pdfHash");

      print("🔗 Storing on blockchain...");
      final txHash = await BlockchainService.storeCertificate(
        certId: certId,
        pdfHash: pdfHash,
      );
      print("✅ Blockchain TX: $txHash");

      print("📱 Generating QR code...");
      final qrBytes = await _generateQRCode(
        certId: certId,
        pdfHash: pdfHash,
        txHash: txHash,
      );

      print("📄 Creating final PDF...");
      final finalPdf = await _createFinalPDF(
        certId: certId,
        name: nameController.text,
        course: selectedCourse!,
        university: selectedUniversity!,
        year: yearController.text,
        reg: regController.text,
        pdfHash: pdfHash,
        txHash: txHash,
        qrBytes: qrBytes,
      );

      print("💾 Saving metadata to Firestore...");
      await _firestore.collection("allCertificates").doc(certId).set({
        "certId": certId,
        "uniqueKey": certId,
        "name": nameController.text,
        "email": emailController.text,
        "registrationNumber": regController.text,
        "course": selectedCourse!,
        "university": selectedUniversity!,
        "year": yearController.text,
        "pdfHash": pdfHash,
        "txHash": txHash,
        "status": "valid",
        "createdAt": FieldValue.serverTimestamp(),
        "createdBy": FirebaseAuth.instance.currentUser?.uid,
      });

      await _firestore.collection("txHashLookup").doc(txHash).set({
        "certId": certId,
        "createdAt": FieldValue.serverTimestamp(),
      });

      _currentCertId = certId;
      _currentTxHash = txHash;

      setState(() => pdfBytes = finalPdf);

      showMsg("✅ Certificate generated! Download or save to Firebase.");
      print("✅ Certificate generation complete: $certId");
    } catch (e) {
      showMsg("❌ Error: $e");
      print("❌ Error generating certificate: $e");
    }

    setState(() => isGenerating = false);
  }

  // ============================================================
  // SAVE PDF TO FIREBASE STORAGE
  // ============================================================
  Future<void> _saveCertificateToFirebase() async {
    if (pdfBytes == null || _currentCertId == null) {
      showMsg("❌ Nothing to save — generate a certificate first.");
      return;
    }

    setState(() => isSaving = true);

    try {
      final certId = _currentCertId!;

      final gzipped = Uint8List.fromList(
        GZipEncoder().encode(pdfBytes!)!,
      );

      final storageRef =
          FirebaseStorage.instance.ref("certificates/$certId.pdf.gz");
      await storageRef.putData(gzipped);
      final downloadUrl = await storageRef.getDownloadURL();

      print("☁️ Uploaded to: $downloadUrl");

      await _firestore
          .collection("allCertificates")
          .doc(certId)
          .update({"storageUrl": downloadUrl});

      showMsg("✅ Certificate saved to Firebase! It is now downloadable.");
      print("✅ storageUrl written for $certId");
    } catch (e) {
      showMsg("❌ Save failed: $e");
      print("❌ Save error: $e");
    }

    setState(() => isSaving = false);
  }

  // ============================================================
  // DOWNLOAD PDF (for web users who can't see preview)
  // ============================================================
  void _downloadPdf() {
    if (pdfBytes == null || _currentCertId == null) return;

    try {
      downloadPdfBytesWeb(pdfBytes!, "$_currentCertId.pdf");
      showMsg("✅ Certificate downloaded!");
    } catch (e) {
      showMsg("❌ Download failed: $e");
    }
  }

  // ============================================================
  // UI
  // ============================================================
  @override
  Widget build(BuildContext context) {
    final isWideScreen = MediaQuery.of(context).size.width > 900;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Certificate Generator"),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: Row(
        children: [
          // ──────── LEFT: form ────────
          Expanded(
            flex: 3,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Generate Certificate",
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 24),
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(
                      labelText: "Student Name",
                      prefixIcon: Icon(Icons.person),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: emailController,
                    decoration: InputDecoration(
                      labelText: "Email",
                      prefixIcon: Icon(Icons.email),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: regController,
                    decoration: InputDecoration(
                      labelText: "Registration Number",
                      prefixIcon: Icon(Icons.badge),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: yearController,
                    decoration: InputDecoration(
                      labelText: "Academic Year (e.g., 2026-27)",
                      prefixIcon: Icon(Icons.calendar_today),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  SizedBox(height: 16),
                  if (universityList.isNotEmpty)
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey[400]!),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: DropdownButton<String>(
                        value: selectedUniversity,
                        isExpanded: true,
                        underline: SizedBox(),
                        items: universityList
                            .map((e) => DropdownMenuItem(
                                  value: e,
                                  child: Text(e),
                                ))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => selectedUniversity = v),
                      ),
                    ),
                  SizedBox(height: 16),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey[400]!),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: DropdownButton<String>(
                      value: selectedCourse,
                      isExpanded: true,
                      underline: SizedBox(),
                      items: courses
                          .map((e) => DropdownMenuItem(
                                value: e,
                                child: Text(e),
                              ))
                          .toList(),
                      onChanged: (v) => setState(() => selectedCourse = v),
                    ),
                  ),
                  SizedBox(height: 24),

                  // ── Generate button ──
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: isGenerating ? null : generateCertificate,
                      icon: isGenerating
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(Icons.create),
                      label: Text(
                        isGenerating ? "Generating..." : "Generate Certificate",
                        style: TextStyle(fontSize: 16),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.indigo,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),

                  // ── Action buttons (visible after generation) ──
                  if (pdfBytes != null) ...[
                    SizedBox(height: 16),

                    // Save to Firebase
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: isSaving ? null : _saveCertificateToFirebase,
                        icon: isSaving
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Icon(Icons.cloud_upload),
                        label: Text(
                          isSaving ? "Saving..." : "Save to Firebase",
                          style: TextStyle(fontSize: 16),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green[700],
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),

                    // Download button (always visible on web since preview doesn't work)
                    if (kIsWeb) ...[
                      SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton.icon(
                          onPressed: _downloadPdf,
                          icon: Icon(Icons.download),
                          label: Text(
                            "Download PDF",
                            style: TextStyle(fontSize: 16),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue[700],
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),

          // ──────── RIGHT: preview panel ────────
          if (isWideScreen && pdfBytes != null)
            Expanded(
              flex: 4,
              child: Container(
                margin: EdgeInsets.all(24),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey[300]!),
                  borderRadius: BorderRadius.circular(12),
                  color: Colors.grey[50],
                ),
                child: kIsWeb
                    ? _buildWebPreviewPlaceholder()
                    : PdfPreview(
                        build: (_) => pdfBytes!,
                        canChangePageFormat: false,
                        canDebug: false,
                      ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Web: show a message instead of broken preview ──
  Widget _buildWebPreviewPlaceholder() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.picture_as_pdf, size: 80, color: Colors.grey[400]),
            SizedBox(height: 20),
            Text(
              "Certificate Generated!",
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.grey[800],
              ),
            ),
            SizedBox(height: 12),
            Text(
              "PDF preview is not available on web.\nUse the download button to view your certificate.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey[600],
              ),
            ),
            SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _downloadPdf,
              icon: Icon(Icons.download),
              label: Text("Download PDF"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue[700],
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
