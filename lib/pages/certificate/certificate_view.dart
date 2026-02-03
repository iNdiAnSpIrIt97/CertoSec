// lib/pages/certificate/certificate_view_page.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // kIsWeb
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:url_launcher/url_launcher.dart';

// This replaces direct 'dart:html'
import '../../utils/pdf_downloader.dart';

class CertificateViewPage extends StatefulWidget {
  @override
  State<CertificateViewPage> createState() => _CertificateViewPageState();
}

class _CertificateViewPageState extends State<CertificateViewPage> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String searchText = "";
  String? filterCourse;
  String? filterUniversity;
  String? filterYear;

  List<String> coursesList = [];
  List<String> universityList = [];
  List<String> yearList = [];

  bool loadingFilters = true;

  // Track which certId is currently being downloaded so we can show a
  // per-card spinner instead of disabling every button.
  String? _downloadingCertId;

  @override
  void initState() {
    super.initState();
    loadFilterData();
  }

  Future<void> loadFilterData() async {
    try {
      final snapshot = await _db.collection("allCertificates").get();

      Set<String> courses = {};
      Set<String> universities = {};
      Set<String> years = {};

      for (var doc in snapshot.docs) {
        courses.add(doc["course"]);
        universities.add(doc["university"]);
        years.add(doc["year"]);
      }

      setState(() {
        coursesList = courses.toList();
        universityList = universities.toList();
        yearList = years.toList();
        loadingFilters = false;
      });
    } catch (e) {
      print("Filter load error: $e");
    }
  }

  bool matchesSearch(Map<String, dynamic> c) {
    final t = searchText.toLowerCase();
    return (c["email"] ?? "").toLowerCase().contains(t) ||
        (c["course"] ?? "").toLowerCase().contains(t) ||
        (c["uniqueKey"] ?? c["certId"] ?? "").toLowerCase().contains(t) ||
        (c["name"] ?? "").toLowerCase().contains(t);
  }

  bool matchesFilters(Map<String, dynamic> c) {
    if (filterCourse != null && c["course"] != filterCourse) return false;
    if (filterUniversity != null && c["university"] != filterUniversity)
      return false;
    if (filterYear != null && c["year"] != filterYear) return false;

    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("All Certificates"),
        backgroundColor: Colors.white,
        elevation: 2,
      ),
      body: Column(
        children: [
          _buildSearchBar(),
          _buildFilterBar(),
          Expanded(child: _buildCertificateList()),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: TextField(
        decoration: InputDecoration(
          hintText: "Search by Name, Email, Course, or Key...",
          prefixIcon: Icon(Icons.search),
          filled: true,
          fillColor: Colors.grey.shade100,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
        onChanged: (v) => setState(() => searchText = v.trim()),
      ),
    );
  }

  Widget _buildFilterBar() {
    if (loadingFilters) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _filterDropdown(
            label: "Course",
            value: filterCourse,
            items: coursesList,
            onChanged: (v) => setState(() => filterCourse = v),
          ),
          _filterDropdown(
            label: "University",
            value: filterUniversity,
            items: universityList,
            onChanged: (v) => setState(() => filterUniversity = v),
          ),
          _filterDropdown(
            label: "Academic Year",
            value: filterYear,
            items: yearList,
            onChanged: (v) => setState(() => filterYear = v),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                filterCourse = null;
                filterUniversity = null;
                filterYear = null;
                searchText = "";
              });
            },
            child: Text("Clear Filters"),
          )
        ],
      ),
    );
  }

  Widget _filterDropdown({
    required String label,
    required String? value,
    required List<String> items,
    required Function(String?) onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: DropdownButton<String>(
          value: value,
          underline: SizedBox(),
          hint: Text(label),
          items: items.map((x) {
            return DropdownMenuItem(value: x, child: Text(x));
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildCertificateList() {
    return StreamBuilder<QuerySnapshot>(
      stream: _db
          .collection("allCertificates")
          .orderBy("createdAt", descending: true)
          .snapshots(),
      builder: (_, snapshot) {
        if (!snapshot.hasData) {
          return Center(child: CircularProgressIndicator());
        }

        final docs = snapshot.data!.docs;

        final certs = docs
            .map((e) => {"id": e.id, ...e.data() as Map<String, dynamic>})
            .toList();

        final filtered = certs
            .where((c) => matchesSearch(c))
            .where((c) => matchesFilters(c))
            .toList();

        if (filtered.isEmpty) {
          return Center(child: Text("No certificates found"));
        }

        int crossAxisCount = MediaQuery.of(context).size.width > 1100
            ? 3
            : MediaQuery.of(context).size.width > 700
                ? 2
                : 1;

        return Padding(
          padding: const EdgeInsets.all(16),
          child: GridView.builder(
            itemCount: filtered.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              childAspectRatio: 1.05,
              mainAxisSpacing: 18,
              crossAxisSpacing: 18,
            ),
            itemBuilder: (_, i) => _certificateCard(filtered[i]),
          ),
        );
      },
    );
  }

  Widget _certificateCard(Map<String, dynamic> c) {
    final certId = c["certId"] ?? c["id"];
    final storageUrl = c["storageUrl"] as String?;
    final isDownloading = _downloadingCertId == certId;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      padding: EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                c["name"] ?? "Unknown",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: 4),
              Text(
                c["email"] ?? "",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.school, size: 18),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      c["course"] ?? "",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.domain, size: 18),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      c["university"] ?? "",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.calendar_month, size: 18),
                  SizedBox(width: 6),
                  Text("Year: ${c["year"] ?? "N/A"}"),
                ],
              ),
              SizedBox(height: 10),
              Text(
                "Key: ${c["uniqueKey"] ?? c["certId"] ?? "N/A"}",
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),

          // ── Download button area ──
          Align(
            alignment: Alignment.bottomRight,
            child: storageUrl == null
                // No storageUrl → certificate was generated but not saved yet
                ? Text(
                    "Not saved to cloud yet",
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[500],
                      fontStyle: FontStyle.italic,
                    ),
                  )
                : ElevatedButton.icon(
                    onPressed: isDownloading
                        ? null
                        : () => downloadFile(certId, storageUrl),
                    icon: isDownloading
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(Icons.download),
                    label: Text(isDownloading ? "..." : "Download"),
                  ),
          ),
        ],
      ),
    );
  }

  /// PLATFORM SAFE DOWNLOAD METHOD
  Future<void> downloadFile(String certId, String storageUrl) async {
    print("Downloading: $storageUrl");

    setState(() => _downloadingCertId = certId);

    try {
      // 1. Load .gz file from Storage
      final ref = FirebaseStorage.instance.refFromURL(storageUrl);
      final Uint8List? gzBytes = await ref.getData();

      if (gzBytes == null) {
        throw Exception("Download failed (null bytes)");
      }

      // 2. Decompress gzip → original PDF bytes
      final pdfBytes = Uint8List.fromList(GZipDecoder().decodeBytes(gzBytes));
      final fileName = ref.name.replaceAll(".gz", "");

      // ── WEB: trigger browser download with the raw PDF bytes ──
      if (kIsWeb) {
        downloadPdfBytesWeb(pdfBytes, fileName);
        setState(() => _downloadingCertId = null);
        return;
      }

      // ── MOBILE: open the gzipped URL directly so the OS handles it ──
      // (most mobile OSes can open PDF URLs natively)
      final uri = Uri.parse(storageUrl);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      print("Download error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Failed to download file")));
      }
    }

    if (mounted) setState(() => _downloadingCertId = null);
  }
}
