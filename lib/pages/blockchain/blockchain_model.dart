// lib/models/blockchain_models.dart

import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Represents a single block in the blockchain
class Block {
  final String blockHash;
  final String previousHash;
  final String certificateHash;
  final Map<String, dynamic> certificateData;
  final DateTime timestamp;
  final int blockNumber;

  Block({
    required this.blockHash,
    required this.previousHash,
    required this.certificateHash,
    required this.certificateData,
    required this.timestamp,
    required this.blockNumber,
  });

  /// Create a new block from certificate data
  factory Block.createNew({
    required String previousHash,
    required Map<String, dynamic> certificateData,
    required int blockNumber,
  }) {
    final timestamp = DateTime.now();

    // Create certificate hash from important fields
    final certificateHash = _hashCertificateData(certificateData);

    // Create block hash combining all block data
    final blockData = {
      'previousHash': previousHash,
      'certificateHash': certificateHash,
      'timestamp': timestamp.toIso8601String(),
      'blockNumber': blockNumber,
    };

    final blockHash = _hashData(blockData);

    return Block(
      blockHash: blockHash,
      previousHash: previousHash,
      certificateHash: certificateHash,
      certificateData: certificateData,
      timestamp: timestamp,
      blockNumber: blockNumber,
    );
  }

  /// Create block from Firestore data
  factory Block.fromMap(Map<String, dynamic> map) {
    return Block(
      blockHash: map['blockHash'] ?? '',
      previousHash: map['previousHash'] ?? '',
      certificateHash: map['certificateHash'] ?? '',
      certificateData: Map<String, dynamic>.from(map['certificateData'] ?? {}),
      timestamp: DateTime.parse(map['timestamp']),
      blockNumber: map['blockNumber'] ?? 0,
    );
  }

  /// Convert to map for Firestore
  Map<String, dynamic> toMap() {
    return {
      'blockHash': blockHash,
      'previousHash': previousHash,
      'certificateHash': certificateHash,
      'certificateData': certificateData,
      'timestamp': timestamp.toIso8601String(),
      'blockNumber': blockNumber,
    };
  }

  /// Hash certificate data (name, email, reg, course, university, year)
  static String _hashCertificateData(Map<String, dynamic> data) {
    final dataToHash = {
      'name': data['name'],
      'email': data['email'],
      'registrationNumber': data['registrationNumber'],
      'course': data['course'],
      'university': data['university'],
      'year': data['year'],
    };
    return _hashData(dataToHash);
  }

  /// Generic hash function using SHA-256
  static String _hashData(Map<String, dynamic> data) {
    final jsonString = json.encode(data);
    final bytes = utf8.encode(jsonString);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Validate if this block's hash is correct
  bool isValid() {
    final blockData = {
      'previousHash': previousHash,
      'certificateHash': certificateHash,
      'timestamp': timestamp.toIso8601String(),
      'blockNumber': blockNumber,
    };

    final calculatedHash = _hashData(blockData);
    return calculatedHash == blockHash;
  }

  /// Validate certificate data matches the stored hash
  bool validateCertificateData(Map<String, dynamic> dataToValidate) {
    final calculatedHash = _hashCertificateData(dataToValidate);
    return calculatedHash == certificateHash;
  }
}

/// Genesis block - the first block in the blockchain
class GenesisBlock extends Block {
  GenesisBlock()
      : super(
          blockHash:
              '0000000000000000000000000000000000000000000000000000000000000000',
          previousHash: '0',
          certificateHash: 'genesis',
          certificateData: {'type': 'genesis', 'description': 'Genesis Block'},
          timestamp: DateTime(2024, 1, 1),
          blockNumber: 0,
        );
}
