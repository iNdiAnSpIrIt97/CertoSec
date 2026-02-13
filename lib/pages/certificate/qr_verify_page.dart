import 'dart:convert';

import 'package:certosec/pages/login/login_page.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/blockchain_verify_service.dart';

class QrVerifyPage extends StatefulWidget {
  const QrVerifyPage({super.key});

  @override
  State<QrVerifyPage> createState() => _QrVerifyPageState();
}

class _QrVerifyPageState extends State<QrVerifyPage> {
  // ── mode: "scan" | "manual" ──
  String mode = "scan";

  bool isScanning = true;
  bool isLoading = false;
  bool? isValid;
  String? error;

  // The Firestore document fetched after a successful resolve
  Map<String, dynamic>? _certDetails;

  // single manual-entry controller
  final inputCtrl = TextEditingController();

  late final MobileScannerController scannerController;

  // ── Firestore & Auth ──
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  User? get currentUser => FirebaseAuth.instance.currentUser;

  String? _userName;
  bool _isLoadingUser = true;

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

    _loadUserName();
  }

  @override
  void dispose() {
    scannerController.dispose();
    inputCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadUserName() async {
    final uid = currentUser?.uid;
    if (uid == null) {
      if (mounted) setState(() => _isLoadingUser = false);
      return;
    }

    try {
      final doc = await _db.collection('users').doc(uid).get();

      if (doc.exists && mounted) {
        setState(() {
          _userName = doc.data()?['name'] as String?;
          _isLoadingUser = false;
        });
      } else {
        if (mounted) setState(() => _isLoadingUser = false);
      }
    } catch (e) {
      debugPrint("Error loading user name: $e");
      if (mounted) setState(() => _isLoadingUser = false);
    }
  }

  Future<void> _logout() async {
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Sign Out"),
        content: const Text("Are you sure you want to log out?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Log Out", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (shouldLogout != true) return;

    await FirebaseAuth.instance.signOut();

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  // ────────────────────────────────────────────────
  // RESET
  // ────────────────────────────────────────────────
  void _reset() {
    setState(() {
      isScanning = true;
      isLoading = false;
      isValid = null;
      error = null;
      _certDetails = null;
    });
  }

  // ────────────────────────────────────────────────
  // HELPERS
  // ────────────────────────────────────────────────
  bool _isTxHash(String s) => s.startsWith("0x") && s.length == 66;

  Future<Map<String, dynamic>?> _fetchCertDoc(String certId) async {
    final doc = await _db.collection("allCertificates").doc(certId).get();
    return doc.exists ? doc.data() : null;
  }

  // ────────────────────────────────────────────────
  // CORE VERIFY
  // ────────────────────────────────────────────────
  Future<void> _runVerification({
    String? qrJson,
    String? manualInput,
  }) async {
    setState(() {
      isScanning = false;
      isLoading = true;
      error = null;
      isValid = null;
      _certDetails = null;
    });

    try {
      String? certId;

      // ── PATH A: QR code ──
      if (qrJson != null) {
        Map<String, dynamic> payload;
        try {
          payload = jsonDecode(qrJson);
        } catch (_) {
          setState(() {
            error = "INVALID_QR";
            isLoading = false;
          });
          return;
        }

        final v = payload["v"];
        if (v != null && v != 1) {
          setState(() {
            error = "INVALID_QR";
            isLoading = false;
          });
          return;
        }

        final type = payload["type"] ?? payload["t"];
        if (type != "CERT") {
          setState(() {
            error = "INVALID_QR";
            isLoading = false;
          });
          return;
        }

        certId = payload["certId"] ?? payload["id"];
        if (certId == null || certId.isEmpty) {
          setState(() {
            error = "INVALID_QR";
            isLoading = false;
          });
          return;
        }
      }

      // ── PATH B: manual input ──
      if (manualInput != null) {
        final trimmed = manualInput.trim();
        if (trimmed.isEmpty) {
          setState(() {
            error = "MANUAL_EMPTY";
            isLoading = false;
          });
          return;
        }

        if (_isTxHash(trimmed)) {
          final lookup =
              await _db.collection("txHashLookup").doc(trimmed).get();
          if (!lookup.exists) {
            setState(() {
              error = "NOT_FOUND";
              isLoading = false;
            });
            return;
          }
          certId = lookup.data()?["certId"] as String?;
          if (certId == null) {
            setState(() {
              error = "NOT_FOUND";
              isLoading = false;
            });
            return;
          }
        } else {
          certId = trimmed;
        }
      }

      if (certId == null) {
        setState(() {
          error = "INVALID_QR";
          isLoading = false;
        });
        return;
      }

      // Fetch certificate
      final certData = await _fetchCertDoc(certId);
      if (certData == null) {
        setState(() {
          error = "NOT_FOUND";
          isLoading = false;
        });
        return;
      }

      final storedHash = certData["pdfHash"] as String?;
      if (storedHash == null || storedHash.isEmpty) {
        setState(() {
          error = "NO_HASH";
          isLoading = false;
        });
        return;
      }

      final valid = await BlockchainVerifyService.verifyCertificate(
        certId: certId,
        pdfHash: storedHash,
      );

      setState(() {
        isValid = valid;
        _certDetails = certData;
        if (!valid) error = "TAMPERED";
      });
    } catch (e) {
      debugPrint("❌ Verify error: $e");
      setState(() => error = "INVALID_QR");
    }

    setState(() => isLoading = false);
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (!isScanning || capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    debugPrint("📱 Raw QR Data: $raw");
    if (raw == null || raw.isEmpty) return;
    await _runVerification(qrJson: raw);
  }

  Future<void> _verifyManual() async {
    await _runVerification(manualInput: inputCtrl.text);
  }

  // ────────────────────────────────────────────────
  // UI
  // ────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // Auto-switch to manual on web
    if (kIsWeb && mode == "scan") {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && mode == "scan") setState(() => mode = "manual");
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Verify Certificate"),
        centerTitle: true,
        actions: [
          if (_isLoadingUser)
            const Padding(
              padding: EdgeInsets.only(right: 20),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            )
          else if (_userName != null && _userName!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "Hi ${_userName!.split(' ').first}",
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.logout),
                    tooltip: 'Sign out',
                    onPressed: _logout,
                  ),
                ],
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          _modeTabs(),
          Expanded(
            child: mode == "scan" ? _scanView() : _manualView(),
          ),
        ],
      ),
    );
  }

  Widget _modeTabs() {
    final tabs = [
      {"key": "scan", "icon": Icons.qr_code_scanner, "label": "Scan QR"},
      {"key": "manual", "icon": Icons.vpn_key, "label": "Enter ID"},
    ];

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: tabs
            .map((t) => Expanded(
                  child: _modeChip(
                    t["key"] as String,
                    t["icon"] as IconData,
                    t["label"] as String,
                  ),
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
              Icon(
                icon,
                color: selected ? Colors.white : Colors.grey[700],
                size: 18,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : Colors.grey[700],
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _scanView() {
    return Column(
      children: [
        if (isScanning)
          Expanded(
            flex: 2,
            child: MobileScanner(
              controller: scannerController,
              onDetect: _onDetect,
            ),
          ),
        Expanded(
          flex: 3,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: _buildResultAndDetails(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _manualView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Certificate ID or Transaction Hash",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.grey[800],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "Enter either one — both are accepted",
            style: TextStyle(fontSize: 13, color: Colors.grey[500]),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: inputCtrl,
            decoration: InputDecoration(
              hintText: "e.g. 1738051200000_ARY128  or  0x…",
              prefixIcon: const Icon(Icons.vpn_key),
              filled: true,
              fillColor: Colors.grey.shade50,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 18),
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
          const SizedBox(height: 28),
          _buildResultAndDetails(),
        ],
      ),
    );
  }

  Widget _buildResultAndDetails() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStatus(),
        if (isValid == true && _certDetails != null) ...[
          const SizedBox(height: 16),
          _detailsCard(_certDetails!),
        ],
      ],
    );
  }

  Widget _buildStatus() {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (error == "INVALID_QR") {
      return _statusBox(
        icon: Icons.qr_code_scanner_rounded,
        color: Colors.orange,
        title: "INVALID QR CODE",
        subtitle:
            "This is not a valid certificate QR code.\n\nPlease scan a QR code from an official CertoSec certificate.",
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
        title: "Input Required",
        subtitle: "Please enter a Certificate ID or Transaction Hash.",
      );
    }

    if (error == "NOT_FOUND") {
      return _statusBox(
        icon: Icons.search_off,
        color: Colors.orange,
        title: "NOT FOUND",
        subtitle:
            "No certificate exists for that ID or transaction hash.\nDouble-check and try again.",
      );
    }

    if (error == "NO_HASH") {
      return _statusBox(
        icon: Icons.lock_open,
        color: Colors.orange,
        title: "MISSING HASH",
        subtitle:
            "The certificate record has no stored hash.\nContact the issuer.",
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

    if (isValid == true) {
      return _statusBox(
        icon: Icons.verified,
        color: Colors.green,
        title: "✓ CERTIFICATE VALID",
        subtitle: "Verified on Blockchain — this certificate is authentic.",
        showReset: false,
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: const [
        Icon(Icons.qr_code_scanner, size: 64, color: Colors.blue),
        SizedBox(height: 12),
        Text(
          "Scan or enter a certificate to verify",
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
    bool showReset = true,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 72, color: color),
        const SizedBox(height: 14),
        Text(
          title,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14),
        ),
        if (showReset) ...[
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _reset,
            icon: const Icon(Icons.refresh),
            label: const Text("Try Again"),
          ),
        ],
      ],
    );
  }

  Widget _detailsCard(Map<String, dynamic> c) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.green.shade300, width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.description, color: Colors.indigo, size: 26),
              const SizedBox(width: 10),
              Text(
                "Certificate Details",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.indigo[800],
                ),
              ),
            ],
          ),
          const Divider(height: 20),
          _detailRow("Name", c["name"]),
          _detailRow("Email", c["email"]),
          _detailRow("Course", c["course"]),
          _detailRow("University", c["university"]),
          _detailRow("Year", c["year"]),
          _detailRow("Registration No.", c["registrationNumber"]),
          _detailRow("Status", c["status"]),
          const SizedBox(height: 10),
          _detailRow("Certificate ID", c["certId"] ?? c["uniqueKey"],
              small: true),
          _detailRow("Transaction Hash", c["txHash"], small: true),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.refresh),
              label: const Text("Scan Another"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, dynamic value, {bool small = false}) {
    final text = value?.toString() ?? "N/A";
    return Padding(
      padding: EdgeInsets.only(bottom: small ? 6 : 8),
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
                color: Colors.grey[600],
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
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
