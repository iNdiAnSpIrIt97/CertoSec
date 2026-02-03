// lib/pages/certificate/qr_scanner_page.dart

import 'dart:ui';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QRScannerPage extends StatefulWidget {
  @override
  State<QRScannerPage> createState() => _QRScannerPageState();
}

class _QRScannerPageState extends State<QRScannerPage>
    with WidgetsBindingObserver {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Map<String, dynamic>? certificateData;
  bool isLoading = false;
  String? errorMsg;

  // Scanner controller
  MobileScannerController? _scannerController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startScanner();
  }

  @override
  void dispose() {
    _scannerController?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_scannerController == null) return;
    if (state == AppLifecycleState.paused) {
      _scannerController!.pause();
    } else if (state == AppLifecycleState.resumed) {
      _scannerController!.start();
    }
  }

  // -------------------------------------------------------------------------
  // START SCANNER
  // -------------------------------------------------------------------------
  void _startScanner() {
    _scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
      torchEnabled: false,
    );
    _scannerController!.start();
    setState(() {});
  }

  // -------------------------------------------------------------------------
  // STOP SCANNER
  // -------------------------------------------------------------------------
  void _stopScanner() {
    _scannerController?.stop();
    _scannerController?.dispose();
    _scannerController = null;
    setState(() {});
  }

  // -------------------------------------------------------------------------
  // VERIFY KEY FROM FIRESTORE
  // -------------------------------------------------------------------------
  Future<void> _verifyKey(String key) async {
    key = key.trim();
    if (key.isEmpty) return;

    setState(() {
      isLoading = true;
      certificateData = null;
      errorMsg = null;
    });

    try {
      final doc = await _db.collection("allCertificates").doc(key).get();

      if (doc.exists) {
        setState(() => certificateData = doc.data()!);
      } else {
        setState(() => errorMsg = "❌ Certificate not found or invalid.");
      }
    } catch (e) {
      setState(() => errorMsg = "Error verifying: $e");
    }

    setState(() => isLoading = false);
  }

  // -------------------------------------------------------------------------
  // ON QR SCAN DETECTED
  // -------------------------------------------------------------------------
  void _onDetect(BarcodeCapture capture) {
    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      if (barcode.rawValue != null) {
        final String qrValue = barcode.rawValue!;
        _stopScanner(); // Stop scanning after successful scan
        _verifyKey(qrValue);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Scanned: $qrValue'),
            backgroundColor: Colors.green,
          ),
        );
        break;
      }
    }
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("QR Code Scanner"),
        backgroundColor: Colors.white,
        elevation: 2,
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                certificateData = null;
                errorMsg = null;
              });
              _startScanner();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Scanner View
          Expanded(
            flex: 2,
            child: _scannerController == null
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.qr_code_scanner,
                            size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text("Scanner not available",
                            style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  )
                : MobileScanner(
                    controller: _scannerController,
                    onDetect: _onDetect,
                    fit: BoxFit.cover,
                  ),
          ),
          // Controls
          if (_scannerController != null)
            Container(
              padding: EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton.icon(
                    onPressed: _stopScanner,
                    icon: Icon(Icons.stop),
                    label: Text("Stop"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: () => _scannerController?.toggleTorch(),
                    icon: Icon(_scannerController!.torchEnabled
                        ? Icons.flash_off
                        : Icons.flash_on),
                    label: Text("Torch"),
                  ),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close),
                    label: Text("Close"),
                  ),
                ],
              ),
            ),
          // Results Area
          Expanded(
            flex: 1,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (isLoading) Center(child: CircularProgressIndicator()),
                  if (errorMsg != null) _errorBox(),
                  if (certificateData != null) _resultCard(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // ERROR UI
  // -------------------------------------------------------------------------
  Widget _errorBox() {
    return Container(
      margin: EdgeInsets.only(top: 12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error, color: Colors.red),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              errorMsg!,
              style: TextStyle(color: Colors.red, fontSize: 16),
            ),
          )
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // RESULT CARD
  // -------------------------------------------------------------------------
  Widget _resultCard() {
    final c = certificateData!;

    return Container(
      margin: EdgeInsets.only(top: 24),
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("✔ Certificate is VALID",
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.green.shade700,
              )),
          SizedBox(height: 20),
          _info("Name", c["name"]),
          _info("Email", c["email"]),
          _info("Course", c["course"]),
          _info("University", c["university"]),
          _info("Year", c["year"]),
          SizedBox(height: 10),
          _info("Verification Key", c["uniqueKey"], small: true),
          SizedBox(height: 20),
          if (c["storageUrl"] != null)
            ElevatedButton.icon(
              onPressed: () {
                // Implement download logic here
              },
              icon: Icon(Icons.download),
              label: Text("Download Certificate"),
            ),
        ],
      ),
    );
  }

  Widget _info(String label, String value, {bool small = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        "$label: $value",
        style: TextStyle(
          fontSize: small ? 13 : 16,
        ),
      ),
    );
  }
}
