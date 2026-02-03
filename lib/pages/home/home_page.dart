import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:certosec/pages/certificate/certificate_generator.dart';
import 'package:certosec/pages/certificate/certificate_validate.dart';
import 'package:certosec/pages/certificate/certificate_view.dart';
import 'package:certosec/pages/certificate/qr_verify_page.dart';

class HomePage extends StatefulWidget {
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String name = "";
  String email = "";
  String role = "";
  bool loading = true;

  int selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    fetchUserData();
  }

  // ---------------------------------------------------------------------------
  // FETCH USER DETAILS
  // ---------------------------------------------------------------------------
  Future<void> fetchUserData() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();

      if (doc.exists) {
        setState(() {
          name = doc['name'];
          email = doc['email'];
          role = doc['role'];
          loading = false;
        });
      } else {
        loading = false;
      }
    } catch (e) {
      debugPrint("User fetch error: $e");
      loading = false;
    }
  }

  // ---------------------------------------------------------------------------
  // SIDEBAR ITEMS
  // ---------------------------------------------------------------------------
  final List<String> menuItems = [
    "Dashboard",
    "Certificate Generation",
    "Certificate Verification",
    "QR Blockchain Verify",
    "Search Student",
    "Logout",
  ];

  IconData _getIcon(int idx) {
    switch (idx) {
      case 0:
        return Icons.dashboard;
      case 1:
        return Icons.picture_as_pdf;
      case 2:
        return Icons.verified;
      case 3:
        return Icons.qr_code_scanner;
      case 4:
        return Icons.search;
      case 5:
        return Icons.logout;
      default:
        return Icons.circle;
    }
  }

  // ---------------------------------------------------------------------------
  // PAGE ROUTING
  // ---------------------------------------------------------------------------
  Widget _buildPage() {
    switch (selectedIndex) {
      case 0:
        return _dashboardOverview();

      case 1:
        return const CertificateGeneratorPage();

      case 2:
        return CertificateValidationPage();

      case 3:
        return const QrVerifyPage();

      case 4:
        return CertificateViewPage();

      case 5:
        FirebaseAuth.instance.signOut();
        Future.microtask(() => Navigator.pop(context));
        return const SizedBox();

      default:
        return const SizedBox();
    }
  }

  // ---------------------------------------------------------------------------
  // DASHBOARD UI
  // ---------------------------------------------------------------------------
  Widget _dashboardOverview() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: GridView.count(
        crossAxisCount: MediaQuery.of(context).size.width > 900 ? 3 : 1,
        crossAxisSpacing: 24,
        mainAxisSpacing: 24,
        children: [
          _dashboardCard(
              Icons.person, "Welcome, $name", email, Colors.blueAccent),
          _dashboardCard(
              Icons.assignment_ind, "Role", role, Colors.deepPurpleAccent),
          _dashboardCard(Icons.security, "Blockchain Secured",
              "Certificates protected on Polygon", Colors.green),
        ],
      ),
    );
  }

  Widget _dashboardCard(
      IconData icon, String title, String subtitle, Color color) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 12, offset: Offset(0, 6))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.white, size: 45),
          const SizedBox(height: 24),
          Text(title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text(subtitle,
              style: TextStyle(
                  color: Colors.white.withOpacity(0.9), fontSize: 16)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SIDEBAR UI
  // ---------------------------------------------------------------------------
  Widget _sideNav(double width) {
    bool collapsed = width < 900;

    return Container(
      width: collapsed ? 70 : 240,
      color: Colors.grey.shade900,
      child: Column(
        children: [
          const SizedBox(height: 30),
          const Icon(Icons.business_center, size: 50, color: Colors.white),
          const SizedBox(height: 20),
          Expanded(
            child: ListView.builder(
              itemCount: menuItems.length,
              itemBuilder: (_, index) {
                final selected = selectedIndex == index;

                return InkWell(
                  onTap: () {
                    setState(() => selectedIndex = index);
                    if (collapsed) Navigator.pop(context);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        vertical: 14, horizontal: 16),
                    color: selected
                        ? Colors.blueAccent.withOpacity(0.3)
                        : Colors.transparent,
                    child: Row(
                      children: [
                        Icon(_getIcon(index),
                            color: selected ? Colors.white : Colors.white70),
                        if (!collapsed) ...[
                          const SizedBox(width: 14),
                          Text(menuItems[index],
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: selected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              )),
                        ]
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 700;

    return Scaffold(
      backgroundColor: Colors.grey.shade200,
      appBar: AppBar(
        title: const Text("ABC COLLEGE"),
        backgroundColor: Colors.black,
        elevation: 2,
        actions: [
          Row(
            children: [
              const CircleAvatar(
                backgroundColor: Colors.black87,
                child: Icon(Icons.person, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Text(name,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(width: 16),
            ],
          ),
        ],
      ),
      drawer: isMobile ? Drawer(child: _sideNav(screenWidth)) : null,
      body: Row(
        children: [
          if (!isMobile) _sideNav(screenWidth),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _buildPage(),
            ),
          ),
        ],
      ),
    );
  }
}