import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/blockchain_service.dart';

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
  Uint8List? pdfBytes;

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
    // Create structured JSON payload
    final payload = jsonEncode({
      "schema": "certosec.v1",
      "type": "CERT",
      "certId": certId,
      "pdfHash": pdfHash,
      "tx": txHash,
      "issuer": "CertoSec",
    });

    print("QR Payload: $payload"); // Debug

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

    // Load logo
    final logoBytes =
        await DefaultAssetBundle.of(context).load('assets/logo.png');
    final logoImage = pw.MemoryImage(logoBytes.buffer.asUint8List());

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
                  // Logo
                  pw.Image(logoImage, width: 90),
                  pw.SizedBox(height: 16),

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

            // QR Code (bottom-right) - CRITICAL: MUST BE VISIBLE
            pw.Positioned(
              right: 36,
              bottom: 130,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Image(
                    pw.MemoryImage(qrBytes),
                    width: 100, // Increased size
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
      // 1️⃣ Generate unique certificate ID
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final certId = "${timestamp}_${regController.text}";

      print("📝 Generating certificate: $certId");

      // 2️⃣ Create base PDF (for hash calculation)
      print("🔐 Creating base PDF for hash...");
      final basePdf = await _createBasePDF(
        name: nameController.text,
        course: selectedCourse!,
        university: selectedUniversity!,
        year: yearController.text,
        reg: regController.text,
      );

      // 3️⃣ Calculate PDF hash
      final pdfHash = generatePdfHash(basePdf);
      print("🔐 PDF Hash: $pdfHash");

      // 4️⃣ Store on blockchain
      print("🔗 Storing on blockchain...");
      final txHash = await BlockchainService.storeCertificate(
        certId: certId,
        pdfHash: pdfHash,
      );
      print("✅ Blockchain TX: $txHash");

      // 5️⃣ Generate QR code with all data
      print("📱 Generating QR code...");
      final qrBytes = await _generateQRCode(
        certId: certId,
        pdfHash: pdfHash,
        txHash: txHash,
      );

      // 6️⃣ Create final PDF with QR code
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

      // 7️⃣ Store in Firestore (with BOTH certId and txHash)
      print("💾 Saving to Firestore...");
      await _firestore.collection("allCertificates").doc(certId).set({
        "certId": certId,
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

      // Also create a txHash lookup document
      await _firestore.collection("txHashLookup").doc(txHash).set({
        "certId": certId,
        "createdAt": FieldValue.serverTimestamp(),
      });

      setState(() => pdfBytes = finalPdf);

      showMsg("✅ Certificate generated successfully!");
      print("✅ Certificate generation complete: $certId");
    } catch (e) {
      showMsg("❌ Error: $e");
      print("❌ Error generating certificate: $e");
    }

    setState(() => isGenerating = false);
  }

  // ============================================================
  // UI
  // ============================================================
  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width > 900;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Certificate Generator"),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: Row(
        children: [
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
                ],
              ),
            ),
          ),
          if (isDesktop && pdfBytes != null)
            Expanded(
              flex: 4,
              child: Container(
                margin: EdgeInsets.all(24),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey[300]!),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: PdfPreview(
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
}
