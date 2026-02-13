// lib/pages/certificate/certificate_validate.dart

import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../services/blockchain_verify_service.dart';

// ---------------------------------------------------------------------------
// Simple result container for blockchain check outcome
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
  List<String> validationSteps = [];

  // ============================================================
  // HELPERS
  // ============================================================
  bool isTxHash(String input) => input.startsWith("0x") && input.length == 66;

  Future<String?> getCertIdFromTxHash(String txHash) async {
    try {
      addValidationStep("🔍 Looking up certificate from transaction hash…");
      final doc = await _db.collection("txHashLookup").doc(txHash).get();
      if (doc.exists) {
        final certId = doc.data()?["certId"] as String?;
        addValidationStep("✅ Found certificate ID: $certId");
        return certId;
      }
      addValidationStep("⚠️ No certificate found for this transaction hash");
      return null;
    } catch (e) {
      addValidationStep("❌ Lookup error: $e");
      return null;
    }
  }

  void addValidationStep(String step) {
    setState(() => validationSteps.add(step));
  }

  void showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ============================================================
  // MAIN VERIFICATION FLOW
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
    });

    try {
      String certId = key;

      // ── resolve txHash → certId if needed ──
      if (isTxHash(key)) {
        addValidationStep("🔗 Transaction hash detected");
        final found = await getCertIdFromTxHash(key);
        if (found == null) {
          setState(() {
            errorMsg = "❌ No certificate found for this transaction hash.";
            isLoading = false;
          });
          return;
        }
        certId = found;
      } else {
        addValidationStep("🔑 Certificate ID detected: $certId");
      }

      // ── fetch Firestore document ──
      addValidationStep("🔍 Fetching certificate from database…");
      final doc = await _db.collection("allCertificates").doc(certId).get();

      if (!doc.exists) {
        setState(() {
          errorMsg = "❌ Certificate not found in database.";
          isLoading = false;
        });
        return;
      }

      final certData = doc.data()!;
      setState(() => certificateData = certData);
      addValidationStep("✅ Certificate found in database");

      // ── status check ──
      if (certData["status"] != "valid") {
        setState(
            () => errorMsg = "⚠️ Certificate status: ${certData["status"]}. "
                "This certificate may have been revoked.");
        addValidationStep("⚠️ Certificate status check failed");
      } else {
        addValidationStep("✅ Certificate status is valid");
      }

      // ── blockchain verification ──
      addValidationStep("🔗 Verifying on blockchain…");
      final storedHash = certData["pdfHash"] as String?;

      if (storedHash == null || storedHash.isEmpty) {
        setState(() {
          errorMsg = "⚠️ No hash stored for this certificate.";
          isLoading = false;
        });
        addValidationStep("❌ Missing hash in database");
        return;
      }

      final isValidOnChain = await BlockchainVerifyService.verifyCertificate(
        certId: certId,
        pdfHash: storedHash,
      );

      setState(() => blockchainValidation = _BlockchainResult(
            isValid: isValidOnChain,
            message: isValidOnChain
                ? "Hash verified on blockchain"
                : "Hash not found on blockchain",
            certId: certId,
          ));

      if (!isValidOnChain) {
        setState(() => errorMsg =
            "⚠️ Blockchain verification failed: hash not found on-chain.");
        addValidationStep("❌ Blockchain verification failed");
      } else {
        addValidationStep("✅ Blockchain verification successful");
      }

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
  // UI BUILD
  // ============================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Certificate Verification"),
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
            const SizedBox(height: 20),
            _keyInputUI(),
            const SizedBox(height: 20),
            if (isLoading) const Center(child: CircularProgressIndicator()),
            if (validationSteps.isNotEmpty) _validationStepsCard(),
            if (errorMsg != null) _errorBox(),
            if (certificateData != null) _resultCard(),
            if (blockchainValidation != null) _blockchainCard(),
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
      padding: const EdgeInsets.all(16),
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
          const Icon(Icons.verified_user, color: Colors.white, size: 40),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Blockchain Verification",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  "Enter a Certificate ID or Transaction Hash",
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _keyInputUI() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Enter Certificate ID or Transaction Hash",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          "Accepts: Certificate ID (e.g. 1738051200000_ARY128) or TX Hash (0x…)",
          style: TextStyle(fontSize: 13, color: Colors.grey[600]),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: keyController,
          decoration: InputDecoration(
            hintText: "Certificate ID or transaction hash…",
            prefixIcon: const Icon(Icons.vpn_key, color: Colors.indigo),
            filled: true,
            fillColor: Colors.grey.shade50,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: Colors.grey[300]!),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Colors.indigo, width: 2),
            ),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton.icon(
            onPressed: isLoading ? null : () => verifyKey(keyController.text),
            icon: const Icon(Icons.search),
            label: const Text("Verify Certificate"),
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

  // ── validation-steps timeline ──
  Widget _validationStepsCard() {
    return Container(
      margin: const EdgeInsets.only(top: 16, bottom: 16),
      padding: const EdgeInsets.all(20),
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
              const Icon(Icons.checklist, color: Colors.indigo, size: 24),
              const SizedBox(width: 12),
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
          const SizedBox(height: 16),
          ...validationSteps.map((step) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("• ", style: TextStyle(fontSize: 16)),
                    Expanded(
                      child: Text(step,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[700],
                          )),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  // ── red error box ──
  Widget _errorBox() {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade200, width: 2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error, color: Colors.red, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(errorMsg!,
                style: TextStyle(color: Colors.red[900], fontSize: 15)),
          ),
        ],
      ),
    );
  }

  // ── certificate details card ──
  Widget _resultCard() {
    final c = certificateData!;

    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.all(20),
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
              const SizedBox(width: 12),
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
          const Divider(height: 24),
          _info("Name", c["name"] ?? "N/A"),
          _info("Email", c["email"] ?? "N/A"),
          _info("Course", c["course"] ?? "N/A"),
          _info("University", c["university"] ?? "N/A"),
          _info("Year", c["year"] ?? "N/A"),
          _info("Registration No.", c["registrationNumber"] ?? "N/A"),
          _info("Status", c["status"] ?? "N/A"),
          const SizedBox(height: 12),
          _info("Certificate ID", c["certId"] ?? c["uniqueKey"] ?? "N/A",
              small: true),
          if (c["txHash"] != null)
            _info("Transaction Hash", c["txHash"], small: true),
        ],
      ),
    );
  }

  // ── blockchain result card ──
  Widget _blockchainCard() {
    final v = blockchainValidation!;
    final ok = v.isValid;

    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: ok ? Colors.green.shade50 : Colors.orange.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: ok ? Colors.green.shade200 : Colors.orange.shade200,
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                ok ? Icons.verified : Icons.warning,
                color: ok ? Colors.green[700] : Colors.orange[700],
                size: 32,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ok ? "✓ Blockchain Verified" : "⚠ Verification Issue",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: ok ? Colors.green[900] : Colors.orange[900],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      v.message,
                      style: TextStyle(
                        color: ok ? Colors.green[700] : Colors.orange[700],
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (v.certId != null) ...[
            const Divider(height: 24),
            Text(
              "Blockchain Information",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: Colors.grey[800],
              ),
            ),
            const SizedBox(height: 12),
            _blockchainInfo("Certificate ID", v.certId!),
            _blockchainInfo(
                "Stored Hash", certificateData?["pdfHash"] ?? "N/A"),
            _blockchainInfo(
                "Transaction Hash", certificateData?["txHash"] ?? "N/A"),
          ],
        ],
      ),
    );
  }

  // ── reusable label / value rows ──
  Widget _blockchainInfo(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
                fontWeight: FontWeight.w600,
              )),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(value,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: Colors.grey[800],
                )),
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
            child: Text("$label:",
                style: TextStyle(
                  fontSize: small ? 12 : 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[700],
                )),
          ),
          Expanded(
            child: SelectableText(value,
                style: TextStyle(
                  fontSize: small ? 12 : 15,
                  color: Colors.grey[900],
                )),
          ),
        ],
      ),
    );
  }
}
