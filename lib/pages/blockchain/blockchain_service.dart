// lib/services/blockchain_service.dart

import 'package:certosec/pages/blockchain/blockchain_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class BlockchainService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Collection name for blockchain
  static const String blockchainCollection = 'blockchain';
  static const String metadataDoc = 'metadata';

  /// Initialize blockchain with genesis block if it doesn't exist
  Future<void> initializeBlockchain() async {
    try {
      final metadataRef =
          _firestore.collection(blockchainCollection).doc(metadataDoc);

      final metadataSnap = await metadataRef.get();

      if (!metadataSnap.exists) {
        // Create genesis block
        final genesisBlock = GenesisBlock();

        // Store genesis block
        await _firestore
            .collection(blockchainCollection)
            .doc('block_0')
            .set(genesisBlock.toMap());

        // Store metadata
        await metadataRef.set({
          'lastBlockNumber': 0,
          'lastBlockHash': genesisBlock.blockHash,
          'totalBlocks': 1,
          'initialized': true,
          'createdAt': FieldValue.serverTimestamp(),
        });

        print('✅ Blockchain initialized with genesis block');
      }
    } catch (e) {
      print('Error initializing blockchain: $e');
      rethrow;
    }
  }

  /// Add a new certificate block to the blockchain
  Future<Block> addCertificateBlock(
      Map<String, dynamic> certificateData) async {
    try {
      // Get current blockchain metadata
      final metadataRef =
          _firestore.collection(blockchainCollection).doc(metadataDoc);

      final metadataSnap = await metadataRef.get();

      if (!metadataSnap.exists) {
        await initializeBlockchain();
        return addCertificateBlock(certificateData);
      }

      final metadata = metadataSnap.data()!;
      final lastBlockNumber = metadata['lastBlockNumber'] as int;
      final lastBlockHash = metadata['lastBlockHash'] as String;

      // Create new block
      final newBlockNumber = lastBlockNumber + 1;
      final newBlock = Block.createNew(
        previousHash: lastBlockHash,
        certificateData: certificateData,
        blockNumber: newBlockNumber,
      );

      // Store new block
      await _firestore
          .collection(blockchainCollection)
          .doc('block_$newBlockNumber')
          .set(newBlock.toMap());

      // Update metadata
      await metadataRef.update({
        'lastBlockNumber': newBlockNumber,
        'lastBlockHash': newBlock.blockHash,
        'totalBlocks': FieldValue.increment(1),
        'lastUpdated': FieldValue.serverTimestamp(),
      });

      print('✅ Block #$newBlockNumber added to blockchain');
      return newBlock;
    } catch (e) {
      print('Error adding block: $e');
      rethrow;
    }
  }

  /// Get a specific block by number
  Future<Block?> getBlock(int blockNumber) async {
    try {
      final doc = await _firestore
          .collection(blockchainCollection)
          .doc('block_$blockNumber')
          .get();

      if (!doc.exists) return null;

      return Block.fromMap(doc.data()!);
    } catch (e) {
      print('Error getting block: $e');
      return null;
    }
  }

  /// Validate a certificate using blockchain
  Future<ValidationResult> validateCertificate({
    required String uniqueKey,
    required Map<String, dynamic> certificateData,
  }) async {
    try {
      // Search for block containing this certificate
      final querySnapshot = await _firestore
          .collection(blockchainCollection)
          .where('certificateData.uniqueKey', isEqualTo: uniqueKey)
          .limit(1)
          .get();

      if (querySnapshot.docs.isEmpty) {
        return ValidationResult(
          isValid: false,
          message: 'Certificate not found in blockchain',
        );
      }

      final blockDoc = querySnapshot.docs.first;
      final block = Block.fromMap(blockDoc.data());

      // Validate block integrity
      if (!block.isValid()) {
        return ValidationResult(
          isValid: false,
          message: 'Block integrity compromised - hash mismatch',
          block: block,
        );
      }

      // Validate certificate data
      if (!block.validateCertificateData(certificateData)) {
        return ValidationResult(
          isValid: false,
          message: 'Certificate data has been tampered with',
          block: block,
        );
      }

      // Validate chain integrity (check previous block)
      if (block.blockNumber > 0) {
        final previousBlock = await getBlock(block.blockNumber - 1);
        if (previousBlock == null) {
          return ValidationResult(
            isValid: false,
            message: 'Previous block missing - chain broken',
            block: block,
          );
        }

        if (previousBlock.blockHash != block.previousHash) {
          return ValidationResult(
            isValid: false,
            message: 'Chain integrity compromised - previous hash mismatch',
            block: block,
          );
        }
      }

      return ValidationResult(
        isValid: true,
        message: 'Certificate is valid and verified on blockchain',
        block: block,
      );
    } catch (e) {
      print('Error validating certificate: $e');
      return ValidationResult(
        isValid: false,
        message: 'Validation error: $e',
      );
    }
  }

  /// Get blockchain statistics
  Future<BlockchainStats> getStats() async {
    try {
      final metadataSnap = await _firestore
          .collection(blockchainCollection)
          .doc(metadataDoc)
          .get();

      if (!metadataSnap.exists) {
        return BlockchainStats(
          totalBlocks: 0,
          lastBlockNumber: -1,
          isInitialized: false,
        );
      }

      final data = metadataSnap.data()!;
      return BlockchainStats(
        totalBlocks: data['totalBlocks'] ?? 0,
        lastBlockNumber: data['lastBlockNumber'] ?? -1,
        lastBlockHash: data['lastBlockHash'],
        isInitialized: data['initialized'] ?? false,
      );
    } catch (e) {
      print('Error getting stats: $e');
      return BlockchainStats(
        totalBlocks: 0,
        lastBlockNumber: -1,
        isInitialized: false,
      );
    }
  }

  /// Verify entire blockchain integrity
  Future<bool> verifyBlockchainIntegrity() async {
    try {
      final stats = await getStats();

      if (!stats.isInitialized || stats.totalBlocks == 0) {
        return false;
      }

      // Check each block
      for (int i = 1; i <= stats.lastBlockNumber; i++) {
        final currentBlock = await getBlock(i);
        final previousBlock = await getBlock(i - 1);

        if (currentBlock == null || previousBlock == null) {
          print('Block $i or ${i - 1} missing');
          return false;
        }

        // Validate current block
        if (!currentBlock.isValid()) {
          print('Block $i hash invalid');
          return false;
        }

        // Validate chain link
        if (currentBlock.previousHash != previousBlock.blockHash) {
          print('Block $i previous hash mismatch');
          return false;
        }
      }

      return true;
    } catch (e) {
      print('Error verifying blockchain: $e');
      return false;
    }
  }
}

/// Result of certificate validation
class ValidationResult {
  final bool isValid;
  final String message;
  final Block? block;

  ValidationResult({
    required this.isValid,
    required this.message,
    this.block,
  });
}

/// Blockchain statistics
class BlockchainStats {
  final int totalBlocks;
  final int lastBlockNumber;
  final String? lastBlockHash;
  final bool isInitialized;

  BlockchainStats({
    required this.totalBlocks,
    required this.lastBlockNumber,
    this.lastBlockHash,
    required this.isInitialized,
  });
}
