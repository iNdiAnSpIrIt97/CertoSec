const { onCall, HttpsError } = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const { ethers } = require("ethers");

// ------------------------------------------------------------
// CONFIG
// ------------------------------------------------------------

const CONTRACT_ADDRESS = "0x5452626f85B93CF8409D2D334f848325B949C8eE";

const CONTRACT_ABI = [
    "function storeCertificate(string certId, string pdfHash) public",
];

// ------------------------------------------------------------
// STORE CERTIFICATE (AUTH REQUIRED)
// ------------------------------------------------------------

exports.storeCertificateOnBlockchain = onCall(
    {
        region: "us-central1",
        timeoutSeconds: 60,
        secrets: ["BLOCKCHAIN_PRIVATE_KEY", "BLOCKCHAIN_RPC_URL"],
    },
    async (request) =>
    {
        try
        {
            // --------------------------------------------------------
            // 🔐 ENFORCE FIREBASE AUTH (THIS FIXES YOUR ISSUE)
            // --------------------------------------------------------
            if (!request.auth)
            {
                throw new HttpsError(
                    "unauthenticated",
                    "Authentication required to store certificate"
                );
            }

            const uid = request.auth.uid;
            logger.info("Authenticated user", { uid });

            // --------------------------------------------------------
            // INPUT VALIDATION
            // --------------------------------------------------------
            const { certId, pdfHash } = request.data || {};

            if (!certId || !pdfHash)
            {
                throw new HttpsError(
                    "invalid-argument",
                    "certId and pdfHash are required"
                );
            }

            // --------------------------------------------------------
            // LOAD SECRETS
            // --------------------------------------------------------
            const PRIVATE_KEY = process.env.BLOCKCHAIN_PRIVATE_KEY;
            const RPC_URL = process.env.BLOCKCHAIN_RPC_URL;

            if (!PRIVATE_KEY || !RPC_URL)
            {
                throw new HttpsError(
                    "failed-precondition",
                    "Blockchain secrets not configured"
                );
            }

            // Extra safety (good practice)
            if (!PRIVATE_KEY.startsWith("0x") || PRIVATE_KEY.length !== 66)
            {
                throw new HttpsError(
                    "failed-precondition",
                    "Invalid blockchain private key format"
                );
            }

            // --------------------------------------------------------
            // BLOCKCHAIN WRITE
            // --------------------------------------------------------
            const provider = new ethers.JsonRpcProvider(RPC_URL);
            const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

            const contract = new ethers.Contract(
                CONTRACT_ADDRESS,
                CONTRACT_ABI,
                wallet
            );

            logger.info("Writing certificate to blockchain", {
                certId,
                uid,
            });

            const tx = await contract.storeCertificate(certId, pdfHash);
            const receipt = await tx.wait();

            logger.info("Blockchain transaction confirmed", {
                txHash: tx.hash,
                blockNumber: receipt.blockNumber,
            });

            // --------------------------------------------------------
            // SUCCESS RESPONSE
            // --------------------------------------------------------
            return {
                success: true,
                txHash: tx.hash,
                blockNumber: receipt.blockNumber,
            };
        } catch (error)
        {
            logger.error("Blockchain store failed", error);

            // Proper Firebase error propagation
            if (error instanceof HttpsError)
            {
                throw error;
            }

            throw new HttpsError(
                "internal",
                error.message || "Blockchain write failed"
            );
        }
    }
);
// ------------------------------------------------------------
// VERIFY CERTIFICATE (PUBLIC – NO AUTH)
// ------------------------------------------------------------
exports.verifyCertificateOnBlockchain = onCall(
    {
        region: "us-central1",
        timeoutSeconds: 30,
    },
    async (request) =>
    {
        try
        {
            const { certId, pdfHash } = request.data || {};

            // --------------------------------------------------------
            // INPUT VALIDATION
            // --------------------------------------------------------
            if (!certId || !pdfHash)
            {
                throw new HttpsError(
                    "invalid-argument",
                    "certId and pdfHash are required"
                );
            }

            // --------------------------------------------------------
            // MOCK BLOCKCHAIN VERIFICATION (STEP 1)
            // --------------------------------------------------------
            const isValidSha256 =
                typeof pdfHash === "string" &&
                /^[a-f0-9]{64}$/i.test(pdfHash);

            if (!isValidSha256)
            {
                return {
                    valid: false,
                    reason: "HASH_NOT_FOUND_ON_CHAIN",
                };
            }

            // --------------------------------------------------------
            // SUCCESS RESPONSE
            // --------------------------------------------------------
            return {
                valid: true,
                certId,
                verifiedAt: Date.now(),
                network: "ethereum",
            };
        } catch (error)
        {
            logger.error("Certificate verification failed", error);

            if (error instanceof HttpsError)
            {
                throw error;
            }

            throw new HttpsError(
                "internal",
                error.message || "Verification failed"
            );
        }
    }
);
