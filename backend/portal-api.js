/**
 * portal-api.js — iOS Client Portal API
 * Mount at /api/portal in server.js
 *
 * Auth: JWT Bearer token (30-day expiry, mobile-friendly)
 * All client-facing routes require requirePortalAuth middleware.
 * Admin routes (create/list portal users) are internal-only.
 */

'use strict';

const express   = require('express');
const router    = express.Router();
const sqlite3   = require('sqlite3').verbose();
const jwt       = require('jsonwebtoken');
const bcrypt    = require('bcryptjs');
const fs        = require('fs');

const DB_PATH   = '/var/www/vanguard/vanguard.db';
const JWT_SECRET = process.env.PORTAL_JWT_SECRET || 'change-me-in-env';
const JWT_EXPIRES = '30d';

// ─── DB helper ──────────────────────────────────────────────────────────────
function getDb() {
    const db = new sqlite3.Database(DB_PATH);
    db.run('PRAGMA journal_mode=WAL');
    db.run('PRAGMA busy_timeout=15000');
    return db;
}

// ─── Bootstrap portal tables ─────────────────────────────────────────────────
(function initPortalTables() {
    const db = getDb();
    db.serialize(() => {
        // password_hash is nullable — NULL = account exists, password not set yet
        db.run(`CREATE TABLE IF NOT EXISTS portal_users (
            id            TEXT PRIMARY KEY,
            client_id     TEXT NOT NULL,
            email         TEXT NOT NULL,
            password_hash TEXT,
            created_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
            last_login    DATETIME
        )`);
        db.run(`CREATE UNIQUE INDEX IF NOT EXISTS idx_portal_users_email
                ON portal_users (LOWER(email))`);

        // Short-lived tokens for password reset (and first-time setup if agent wants token flow)
        db.run(`CREATE TABLE IF NOT EXISTS portal_tokens (
            token      TEXT PRIMARY KEY,
            user_id    TEXT NOT NULL,
            type       TEXT NOT NULL,
            expires_at DATETIME NOT NULL,
            used       INTEGER DEFAULT 0
        )`);

        db.run(`CREATE TABLE IF NOT EXISTS portal_certificate_holders (
            id         TEXT PRIMARY KEY,
            client_id  TEXT,
            name       TEXT NOT NULL,
            company    TEXT DEFAULT '',
            address    TEXT DEFAULT '',
            city       TEXT DEFAULT '',
            state      TEXT DEFAULT '',
            zip        TEXT DEFAULT '',
            is_global  INTEGER DEFAULT 0,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )`);

        db.run(`CREATE TABLE IF NOT EXISTS portal_coi_requests (
            id                    TEXT PRIMARY KEY,
            client_id             TEXT NOT NULL,
            policy_id             TEXT NOT NULL,
            policy_number         TEXT DEFAULT '',
            request_type          TEXT DEFAULT 'standard',
            recipient_emails      TEXT DEFAULT '[]',
            certificate_holder    TEXT DEFAULT '',
            additional_notes      TEXT DEFAULT '',
            status                TEXT DEFAULT 'pending',
            submitted_at          DATETIME DEFAULT CURRENT_TIMESTAMP,
            completed_at          DATETIME,
            agent_notes           TEXT DEFAULT ''
        )`);
    });
    db.close();
})();

// ─── Auth middleware ──────────────────────────────────────────────────────────
function requirePortalAuth(req, res, next) {
    const auth  = req.headers.authorization || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7).trim() : null;
    if (!token) return res.status(401).json({ error: 'Missing Authorization header' });
    try {
        req.portalUser = jwt.verify(token, JWT_SECRET);
        next();
    } catch (e) {
        const expired = e.name === 'TokenExpiredError';
        res.status(401).json({ error: expired ? 'Token expired' : 'Invalid token' });
    }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────
const POLICY_TYPE_LABELS = {
    'commercial-auto'   : 'Commercial Auto',
    'general-liability' : 'General Liability',
    'workers-comp'      : "Workers' Compensation",
    'property'          : 'Commercial Property',
    'umbrella'          : 'Umbrella / Excess',
    'cargo'             : 'Motor Truck Cargo',
    'physical-damage'   : 'Physical Damage',
    'bop'               : 'Business Owners Policy',
    'cyber'             : 'Cyber Liability',
};

function policyLabel(type) {
    return POLICY_TYPE_LABELS[(type || '').toLowerCase()] || type || 'Policy';
}

function docTypeFromName(filename) {
    const n = (filename || '').toLowerCase();
    if (n.includes('id-card') || n.includes('id_card') || n.includes('idcard')) return 'id_card';
    if (n.includes('dec ') || n.includes('declaration') || n.includes('_dec_') || n.includes('-dec-')) return 'declaration';
    if (n.includes('billing') || n.includes('invoice') || n.includes('statement')) return 'billing';
    if (n.includes('coi') || n.includes('certificate')) return 'coi';
    if (n.includes('loss-run') || n.includes('loss_run') || n.includes('lossrun')) return 'loss_run';
    if (n.includes('quote')) return 'quote';
    return 'document';
}

// ─── Shared: issue a JWT for a verified portal_user row ──────────────────────
function issueToken(db, user, res) {
    db.get('SELECT data FROM clients WHERE id=?', [user.client_id], (err, clientRow) => {
        db.run('UPDATE portal_users SET last_login=CURRENT_TIMESTAMP WHERE id=?', [user.id]);
        db.close();
        let name = '';
        try { name = JSON.parse(clientRow.data).name || ''; } catch {}
        const token = jwt.sign(
            { sub: user.client_id, userId: user.id, email: user.email },
            JWT_SECRET,
            { expiresIn: JWT_EXPIRES }
        );
        res.json({ token, expiresIn: JWT_EXPIRES, clientId: user.client_id, name });
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// PUBLIC: POST /api/portal/login
//
// Distinct failure codes so the iOS app can branch UI:
//   404 EMAIL_NOT_FOUND   — no portal account for this email
//   403 PASSWORD_NOT_SET  — account exists but password never set (show Setup screen)
//   401 WRONG_PASSWORD    — account + password set, but password is incorrect
//   200                   — success → { token, expiresIn, clientId, name }
// ─────────────────────────────────────────────────────────────────────────────
router.post('/login', (req, res) => {
    const { email, password } = req.body || {};
    if (!email || !password)
        return res.status(400).json({ code: 'MISSING_FIELDS', error: 'email and password are required' });

    const db = getDb();
    db.get(
        'SELECT * FROM portal_users WHERE LOWER(email)=LOWER(?)',
        [email.trim()],
        (err, user) => {
            if (err) { db.close(); return res.status(500).json({ error: 'Database error' }); }

            // ── 404: email not registered ──────────────────────────────────
            if (!user) {
                db.close();
                return res.status(404).json({
                    code  : 'EMAIL_NOT_FOUND',
                    error : 'No account found for this email address',
                });
            }

            // ── 403: account exists but password not set yet ───────────────
            if (!user.password_hash) {
                db.close();
                return res.status(403).json({
                    code  : 'PASSWORD_NOT_SET',
                    error : 'Your account exists but a password has not been set up yet',
                });
            }

            // ── 401: password set but wrong ────────────────────────────────
            bcrypt.compare(password, user.password_hash, (bcErr, match) => {
                if (!match) {
                    db.close();
                    return res.status(401).json({
                        code  : 'WRONG_PASSWORD',
                        error : 'Incorrect password',
                    });
                }
                // ── 200: success ───────────────────────────────────────────
                issueToken(db, user, res);
            });
        }
    );
});

// ─────────────────────────────────────────────────────────────────────────────
// PUBLIC: POST /api/portal/setup-password
// First-time password creation. Only works when password_hash IS NULL.
// Use /request-password-reset instead for forgotten passwords.
//
// Body:   { email, newPassword }
// 404    EMAIL_NOT_FOUND  — not a registered portal user
// 409    PASSWORD_ALREADY_SET — use reset flow instead
// 400    WEAK_PASSWORD — fewer than 8 characters
// 200    { token, ... } — password saved + logged in
// ─────────────────────────────────────────────────────────────────────────────
router.post('/setup-password', (req, res) => {
    const { email, newPassword } = req.body || {};
    if (!email || !newPassword)
        return res.status(400).json({ code: 'MISSING_FIELDS', error: 'email and newPassword are required' });
    if (newPassword.length < 8)
        return res.status(400).json({ code: 'WEAK_PASSWORD', error: 'Password must be at least 8 characters' });

    const db = getDb();
    db.get('SELECT * FROM portal_users WHERE LOWER(email)=LOWER(?)', [email.trim()], (err, user) => {
        if (err)  { db.close(); return res.status(500).json({ error: 'Database error' }); }
        if (!user){ db.close(); return res.status(404).json({ code: 'EMAIL_NOT_FOUND', error: 'No account found for this email address' }); }
        if (user.password_hash) {
            db.close();
            return res.status(409).json({ code: 'PASSWORD_ALREADY_SET', error: 'A password is already set. Use the forgot password flow to reset it.' });
        }

        bcrypt.hash(newPassword, 10, (hashErr, hash) => {
            if (hashErr) { db.close(); return res.status(500).json({ error: 'Server error' }); }
            db.run('UPDATE portal_users SET password_hash=? WHERE id=?', [hash, user.id], (e) => {
                if (e) { db.close(); return res.status(500).json({ error: 'Failed to save password' }); }
                issueToken(db, { ...user, password_hash: hash }, res);
            });
        });
    });
});

// ─────────────────────────────────────────────────────────────────────────────
// PUBLIC: POST /api/portal/request-password-reset
// Generates a 15-minute reset token. In production this would be emailed;
// for now the token is returned in the response so you can test immediately.
//
// Body:  { email }
// Always 200 — never reveals whether the email exists (security best practice)
// Response: { message, resetToken (dev only), expiresIn }
// ─────────────────────────────────────────────────────────────────────────────
router.post('/request-password-reset', (req, res) => {
    const { email } = req.body || {};
    if (!email)
        return res.status(400).json({ code: 'MISSING_FIELDS', error: 'email is required' });

    const db = getDb();
    db.get('SELECT * FROM portal_users WHERE LOWER(email)=LOWER(?)', [email.trim()], (err, user) => {
        if (err || !user) {
            db.close();
            // Don't leak whether email exists — always return the same message
            return res.json({ message: 'If that email is registered, a reset token has been generated.' });
        }

        const resetToken  = require('crypto').randomBytes(32).toString('hex');
        const expiresAt   = new Date(Date.now() + 15 * 60 * 1000).toISOString(); // 15 min
        const tokenId     = 'RT-' + Date.now();

        db.run(
            `INSERT INTO portal_tokens (token, user_id, type, expires_at) VALUES (?,?,?,?)`,
            [resetToken, user.id, 'reset', expiresAt],
            (insertErr) => {
                db.close();
                if (insertErr) return res.status(500).json({ error: 'Failed to generate token' });
                res.json({
                    message   : 'Reset token generated. Share this with the user to complete the reset.',
                    resetToken,          // remove/email this in production
                    expiresIn : '15 minutes',
                });
            }
        );
    });
});

// ─────────────────────────────────────────────────────────────────────────────
// PUBLIC: POST /api/portal/complete-password-reset
// Validates reset token, sets new password, returns JWT.
//
// Body: { resetToken, newPassword }
// 400   INVALID_TOKEN — token not found, expired, or already used
// 400   WEAK_PASSWORD
// 200   { token, ... } — password updated + logged in
// ─────────────────────────────────────────────────────────────────────────────
router.post('/complete-password-reset', (req, res) => {
    const { resetToken, newPassword } = req.body || {};
    if (!resetToken || !newPassword)
        return res.status(400).json({ code: 'MISSING_FIELDS', error: 'resetToken and newPassword are required' });
    if (newPassword.length < 8)
        return res.status(400).json({ code: 'WEAK_PASSWORD', error: 'Password must be at least 8 characters' });

    const db = getDb();
    db.get(
        `SELECT * FROM portal_tokens WHERE token=? AND type='reset' AND used=0 AND expires_at > CURRENT_TIMESTAMP`,
        [resetToken],
        (err, tokenRow) => {
            if (err || !tokenRow) {
                db.close();
                return res.status(400).json({ code: 'INVALID_TOKEN', error: 'Reset token is invalid, expired, or already used' });
            }

            db.get('SELECT * FROM portal_users WHERE id=?', [tokenRow.user_id], (uErr, user) => {
                if (uErr || !user) { db.close(); return res.status(404).json({ error: 'Account not found' }); }

                bcrypt.hash(newPassword, 10, (hashErr, hash) => {
                    if (hashErr) { db.close(); return res.status(500).json({ error: 'Server error' }); }
                    db.serialize(() => {
                        db.run('UPDATE portal_users SET password_hash=? WHERE id=?', [hash, user.id]);
                        db.run('UPDATE portal_tokens SET used=1 WHERE token=?', [resetToken]);
                    });
                    issueToken(db, { ...user, password_hash: hash }, res);
                });
            });
        }
    );
});

// ─────────────────────────────────────────────────────────────────────────────
// PROTECTED: GET /api/portal/me
// Returns the logged-in client's profile
// ─────────────────────────────────────────────────────────────────────────────
router.get('/me', requirePortalAuth, (req, res) => {
    const db = getDb();
    db.get('SELECT id, data FROM clients WHERE id=?', [req.portalUser.sub], (err, row) => {
        db.close();
        if (err || !row) return res.status(404).json({ error: 'Client not found' });
        try {
            const d = JSON.parse(row.data);
            res.json({
                accountId    : String(row.id),
                name         : d.name         || d.fullName    || '',
                fullName     : d.fullName      || d.name        || '',
                businessName : d.businessName  || '',
                email        : d.email         || '',
                phone        : d.phone         || '',
                address      : d.address       || '',
                city         : d.city          || '',
                state        : d.state         || '',
                zip          : d.zip           || '',
                type         : d.type          || 'Commercial',
                status       : d.status        || 'Active',
                assignedAgent: d.assignedTo    || '',
            });
        } catch {
            res.status(500).json({ error: 'Failed to parse client data' });
        }
    });
});

// ─────────────────────────────────────────────────────────────────────────────
// PROTECTED: GET /api/portal/policies
// Returns all active policies for the logged-in client
// ─────────────────────────────────────────────────────────────────────────────
router.get('/policies', requirePortalAuth, (req, res) => {
    const db = getDb();
    db.all('SELECT id, data FROM policies WHERE client_id=?', [req.portalUser.sub], (err, rows) => {
        db.close();
        if (err) return res.status(500).json({ error: 'Database error' });

        const policies = [];
        for (const row of (rows || [])) {
            try {
                const outer = JSON.parse(row.data);
                for (const p of (outer.policies || [])) {
                    policies.push({
                        policyId        : String(row.id),
                        policyNumber    : p.policyNumber    || '',
                        policyType      : p.policyType      || '',
                        policyName      : policyLabel(p.policyType),
                        carrier         : p.carrier         || '',
                        status          : p.policyStatus    || 'Active',
                        effectiveDate   : p.effectiveDate   || '',
                        expirationDate  : p.expirationDate  || '',
                        premium         : String(p.premium  || '0').replace(/[^0-9.]/g, ''),
                        insuredName     : (p.insured || {})['Name/Business Name'] || (p.insured || {})['Primary Named Insured'] || '',
                        dotNumber       : p.dotNumber       || '',
                        mcNumber        : p.mcNumber        || '',
                        agent           : p.agent           || '',
                    });
                }
            } catch { /* skip unparseable rows */ }
        }

        // Sort active first, then by expiration date desc
        policies.sort((a, b) => {
            if (a.status === 'Active' && b.status !== 'Active') return -1;
            if (a.status !== 'Active' && b.status === 'Active') return  1;
            return (b.expirationDate || '').localeCompare(a.expirationDate || '');
        });

        res.json({ policies, count: policies.length });
    });
});

// ─────────────────────────────────────────────────────────────────────────────
// PROTECTED: GET /api/portal/policies/:policyId/documents
// Returns all documents (uploads + COIs) for a specific policy
// ─────────────────────────────────────────────────────────────────────────────
router.get('/policies/:policyId/documents', requirePortalAuth, (req, res) => {
    const { policyId } = req.params;
    const db = getDb();

    // Verify ownership first
    db.get('SELECT id FROM policies WHERE id=? AND client_id=?',
        [policyId, req.portalUser.sub],
        (err, pol) => {
            if (err || !pol) {
                db.close();
                return res.status(403).json({ error: 'Policy not found or access denied' });
            }

            db.all(
                'SELECT * FROM documents WHERE policy_id=?',
                [policyId],
                (e1, docs) => {
                    db.all(
                        'SELECT id, name, type, upload_date FROM coi_documents WHERE policy_id=?',
                        [policyId],
                        (e2, cois) => {
                            db.close();

                            const result = [];

                            for (const d of (docs || [])) {
                                result.push({
                                    id          : d.id,
                                    docType     : docTypeFromName(d.original_name || d.filename),
                                    name        : d.original_name || d.filename,
                                    mimeType    : d.file_type,
                                    fileSize    : d.file_size,
                                    uploadDate  : d.upload_date,
                                    downloadUrl : `/api/portal/documents/${d.id}/download`,
                                    source      : 'upload',
                                });
                            }

                            for (const c of (cois || [])) {
                                result.push({
                                    id          : c.id,
                                    docType     : 'coi',
                                    name        : c.name || 'Certificate of Insurance',
                                    mimeType    : 'application/pdf',
                                    uploadDate  : c.upload_date,
                                    downloadUrl : `/api/portal/coi-documents/${c.id}/download`,
                                    source      : 'coi_documents',
                                });
                            }

                            result.sort((a, b) =>
                                (b.uploadDate || '').localeCompare(a.uploadDate || ''));

                            res.json({ documents: result, count: result.length });
                        }
                    );
                }
            );
        }
    );
});

// ─────────────────────────────────────────────────────────────────────────────
// PROTECTED: GET /api/portal/documents/:docId/download
// Streams an uploaded document (PDF, image, etc.)
// ─────────────────────────────────────────────────────────────────────────────
router.get('/documents/:docId/download', requirePortalAuth, (req, res) => {
    const db = getDb();
    db.get(
        'SELECT * FROM documents WHERE id=? AND client_id=?',
        [req.params.docId, req.portalUser.sub],
        (err, doc) => {
            db.close();
            if (err || !doc) return res.status(404).json({ error: 'Document not found' });
            if (!doc.file_path || !fs.existsSync(doc.file_path))
                return res.status(404).json({ error: 'File not on disk' });

            const name = doc.original_name || doc.filename || 'document';
            res.setHeader('Content-Type', doc.file_type || 'application/octet-stream');
            res.setHeader('Content-Disposition', `inline; filename="${name}"`);
            fs.createReadStream(doc.file_path).pipe(res);
        }
    );
});

// ─────────────────────────────────────────────────────────────────────────────
// PROTECTED: GET /api/portal/coi-documents/:id/download
// Returns the binary PDF for a COI stored as base64 dataUrl
// ─────────────────────────────────────────────────────────────────────────────
router.get('/coi-documents/:id/download', requirePortalAuth, (req, res) => {
    const db = getDb();
    db.get(
        `SELECT c.* FROM coi_documents c
         JOIN policies p ON p.id = c.policy_id
         WHERE c.id=? AND p.client_id=?`,
        [req.params.id, req.portalUser.sub],
        (err, doc) => {
            db.close();
            if (err || !doc) return res.status(404).json({ error: 'COI not found' });

            if (doc.data_url && doc.data_url.startsWith('data:')) {
                const [, b64] = doc.data_url.split(',');
                const buf = Buffer.from(b64 || doc.data_url, 'base64');
                res.setHeader('Content-Type', 'application/pdf');
                res.setHeader('Content-Disposition', `inline; filename="${doc.name || 'coi.pdf'}"`);
                return res.send(buf);
            }
            if (doc.data_url) return res.redirect(doc.data_url);
            res.status(404).json({ error: 'No file data available' });
        }
    );
});

// ─────────────────────────────────────────────────────────────────────────────
// PROTECTED: GET /api/portal/certificate-holders
// Returns global cert holders + ones this client has saved
// ─────────────────────────────────────────────────────────────────────────────
router.get('/certificate-holders', requirePortalAuth, (req, res) => {
    const db = getDb();
    db.all(
        `SELECT * FROM portal_certificate_holders
         WHERE is_global=1 OR client_id=?
         ORDER BY name COLLATE NOCASE`,
        [req.portalUser.sub],
        (err, rows) => {
            db.close();
            if (err) return res.status(500).json({ error: 'Database error' });
            res.json({
                certificateHolders: (rows || []).map(r => ({
                    id       : r.id,
                    name     : r.name,
                    company  : r.company  || '',
                    address  : r.address  || '',
                    city     : r.city     || '',
                    state    : r.state    || '',
                    zip      : r.zip      || '',
                    isGlobal : !!r.is_global,
                })),
            });
        }
    );
});

// ─────────────────────────────────────────────────────────────────────────────
// PROTECTED: POST /api/portal/certificate-holders
// Save a new cert holder for this client
// ─────────────────────────────────────────────────────────────────────────────
router.post('/certificate-holders', requirePortalAuth, (req, res) => {
    const { name, company, address, city, state, zip } = req.body || {};
    if (!name) return res.status(400).json({ error: 'name is required' });

    const id = 'CH-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8);
    const db = getDb();
    db.run(
        `INSERT INTO portal_certificate_holders
         (id, client_id, name, company, address, city, state, zip, is_global)
         VALUES (?,?,?,?,?,?,?,?,0)`,
        [id, req.portalUser.sub, name, company||'', address||'', city||'', state||'', zip||''],
        (err) => {
            db.close();
            if (err) return res.status(500).json({ error: 'Failed to save certificate holder' });
            res.status(201).json({ id, name, company, address, city, state, zip, isGlobal: false });
        }
    );
});

// ─────────────────────────────────────────────────────────────────────────────
// PROTECTED: POST /api/portal/coi/request
// Submit a COI request from the app
//
// Body:
// {
//   policyId: string,           required
//   requestType: "myself"|"third_party",
//   recipientEmails: string[],
//   certificateHolder: {        optional
//     name, company, address, city, state, zip
//   },
//   additionalNotes: string
// }
// ─────────────────────────────────────────────────────────────────────────────
router.post('/coi/request', requirePortalAuth, (req, res) => {
    const {
        policyId,
        requestType        = 'myself',
        recipientEmails    = [],
        certificateHolder  = null,
        additionalNotes    = '',
    } = req.body || {};

    if (!policyId)
        return res.status(400).json({ error: 'policyId is required' });

    const db = getDb();
    db.get(
        'SELECT id, data FROM policies WHERE id=? AND client_id=?',
        [policyId, req.portalUser.sub],
        (err, pol) => {
            if (err || !pol) {
                db.close();
                return res.status(403).json({ error: 'Policy not found or access denied' });
            }

            let policyNumber = '';
            try {
                const d = JSON.parse(pol.data);
                policyNumber = ((d.policies || [])[0] || {}).policyNumber || '';
            } catch {}

            const id = 'COIREQ-' + Date.now() + '-' + Math.random().toString(36).slice(2, 6);
            db.run(
                `INSERT INTO portal_coi_requests
                 (id, client_id, policy_id, policy_number, request_type,
                  recipient_emails, certificate_holder, additional_notes, status)
                 VALUES (?,?,?,?,?,?,?,?,'pending')`,
                [
                    id,
                    req.portalUser.sub,
                    policyId,
                    policyNumber,
                    requestType,
                    JSON.stringify(recipientEmails),
                    certificateHolder ? JSON.stringify(certificateHolder) : '',
                    additionalNotes,
                ],
                (e) => {
                    db.close();
                    if (e) return res.status(500).json({ error: 'Failed to submit request' });
                    res.status(201).json({
                        requestId      : id,
                        status         : 'pending',
                        message        : 'COI request submitted. Your agent will process it within 1 business day.',
                        estimatedTime  : '1 business day',
                    });
                }
            );
        }
    );
});

// ─────────────────────────────────────────────────────────────────────────────
// PROTECTED: GET /api/portal/coi/requests
// List this client's COI requests with status
// ─────────────────────────────────────────────────────────────────────────────
router.get('/coi/requests', requirePortalAuth, (req, res) => {
    const db = getDb();
    db.all(
        `SELECT * FROM portal_coi_requests WHERE client_id=? ORDER BY submitted_at DESC`,
        [req.portalUser.sub],
        (err, rows) => {
            db.close();
            if (err) return res.status(500).json({ error: 'Database error' });
            res.json({
                requests: (rows || []).map(r => ({
                    requestId          : r.id,
                    policyId           : r.policy_id,
                    policyNumber       : r.policy_number,
                    requestType        : r.request_type,
                    recipientEmails    : JSON.parse(r.recipient_emails || '[]'),
                    certificateHolder  : r.certificate_holder ? JSON.parse(r.certificate_holder) : null,
                    additionalNotes    : r.additional_notes,
                    status             : r.status,
                    submittedAt        : r.submitted_at,
                    completedAt        : r.completed_at || null,
                    agentNotes         : r.agent_notes  || '',
                })),
            });
        }
    );
});

// ─────────────────────────────────────────────────────────────────────────────
// ADMIN: POST /api/portal/admin/users
// Create a portal account for a CRM client.
// password is optional — omit it to create an unactivated account that
// triggers PASSWORD_NOT_SET on login, prompting the client to set up their
// own password via POST /setup-password.
//
// Body: { clientId, email, password? }
// ─────────────────────────────────────────────────────────────────────────────
router.post('/admin/users', (req, res) => {
    const { clientId, email, password } = req.body || {};
    if (!clientId || !email)
        return res.status(400).json({ error: 'clientId and email are required' });
    if (password && password.length < 8)
        return res.status(400).json({ error: 'Password must be at least 8 characters' });

    const id = 'PU-' + Date.now();

    function saveUser(hash) {
        const db = getDb();
        db.get('SELECT id FROM clients WHERE id=?', [clientId], (cErr, client) => {
            if (!client) { db.close(); return res.status(404).json({ error: 'Client not found in CRM' }); }
            db.run(
                `INSERT INTO portal_users (id, client_id, email, password_hash)
                 VALUES (?, ?, LOWER(?), ?)
                 ON CONFLICT(LOWER(email)) DO UPDATE SET
                     password_hash = COALESCE(excluded.password_hash, password_hash),
                     client_id     = excluded.client_id`,
                [id, clientId, email, hash || null],
                (e) => {
                    db.close();
                    if (e) return res.status(500).json({ error: e.message });
                    res.status(201).json({
                        id, clientId,
                        email        : email.toLowerCase(),
                        passwordSet  : !!hash,
                        message      : hash
                            ? 'Portal user created with password. Client can log in immediately.'
                            : 'Portal account created without password. Client will be prompted to set one on first login.',
                    });
                }
            );
        });
    }

    if (password) {
        bcrypt.hash(password, 10, (err, hash) => {
            if (err) return res.status(500).json({ error: 'Server error' });
            saveUser(hash);
        });
    } else {
        saveUser(null);
    }
});

// ─────────────────────────────────────────────────────────────────────────────
// ADMIN: GET /api/portal/admin/users — list all portal users
// ─────────────────────────────────────────────────────────────────────────────
router.get('/admin/users', (req, res) => {
    const db = getDb();
    db.all(
        `SELECT pu.id, pu.client_id, pu.email, pu.created_at, pu.last_login,
                json_extract(c.data, '$.name') AS client_name
         FROM portal_users pu
         LEFT JOIN clients c ON c.id = pu.client_id
         ORDER BY pu.created_at DESC`,
        (err, rows) => {
            db.close();
            if (err) return res.status(500).json({ error: 'Database error' });
            res.json({ users: rows || [] });
        }
    );
});

// ─────────────────────────────────────────────────────────────────────────────
// ADMIN: DELETE /api/portal/admin/users/:id — revoke portal access
// ─────────────────────────────────────────────────────────────────────────────
router.delete('/admin/users/:id', (req, res) => {
    const db = getDb();
    db.run('DELETE FROM portal_users WHERE id=?', [req.params.id], function(err) {
        db.close();
        if (err) return res.status(500).json({ error: 'Database error' });
        if (this.changes === 0) return res.status(404).json({ error: 'User not found' });
        res.json({ message: 'Portal access revoked' });
    });
});

// ─────────────────────────────────────────────────────────────────────────────
// ADMIN: POST /api/portal/admin/certificate-holders
// Seed a global certificate holder available to all clients
// ─────────────────────────────────────────────────────────────────────────────
router.post('/admin/certificate-holders', (req, res) => {
    const { name, company, address, city, state, zip } = req.body || {};
    if (!name) return res.status(400).json({ error: 'name is required' });

    const id = 'GCH-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8);
    const db = getDb();
    db.run(
        `INSERT INTO portal_certificate_holders
         (id, client_id, name, company, address, city, state, zip, is_global)
         VALUES (?,NULL,?,?,?,?,?,?,1)`,
        [id, name, company||'', address||'', city||'', state||'', zip||''],
        (err) => {
            db.close();
            if (err) return res.status(500).json({ error: 'Failed to save' });
            res.status(201).json({ id, name, company, address, city, state, zip, isGlobal: true });
        }
    );
});

// ─────────────────────────────────────────────────────────────────────────────
// ADMIN: GET /api/portal/admin/coi-requests — view pending requests from app
// ─────────────────────────────────────────────────────────────────────────────
router.get('/admin/coi-requests', (req, res) => {
    const db = getDb();
    db.all(
        `SELECT r.*,
                json_extract(c.data, '$.name') AS client_name,
                json_extract(c.data, '$.email') AS client_email,
                json_extract(c.data, '$.phone') AS client_phone
         FROM portal_coi_requests r
         LEFT JOIN clients c ON c.id = r.client_id
         ORDER BY r.submitted_at DESC`,
        (err, rows) => {
            db.close();
            if (err) return res.status(500).json({ error: 'Database error' });
            res.json({
                requests: (rows || []).map(r => ({
                    ...r,
                    recipientEmails   : JSON.parse(r.recipient_emails   || '[]'),
                    certificateHolder : r.certificate_holder ? JSON.parse(r.certificate_holder) : null,
                })),
            });
        }
    );
});

// ─────────────────────────────────────────────────────────────────────────────
// ADMIN: PUT /api/portal/admin/coi-requests/:id — update status / add notes
// Body: { status: 'completed'|'in_progress'|'cancelled', agentNotes: '' }
// ─────────────────────────────────────────────────────────────────────────────
router.put('/admin/coi-requests/:id', (req, res) => {
    const { status, agentNotes } = req.body || {};
    const db = getDb();
    const completedAt = (status === 'completed') ? new Date().toISOString() : null;
    db.run(
        `UPDATE portal_coi_requests
         SET status=COALESCE(?,status), agent_notes=COALESCE(?,agent_notes),
             completed_at=COALESCE(?,completed_at)
         WHERE id=?`,
        [status||null, agentNotes||null, completedAt, req.params.id],
        function(err) {
            db.close();
            if (err) return res.status(500).json({ error: 'Database error' });
            if (this.changes === 0) return res.status(404).json({ error: 'Request not found' });
            res.json({ message: 'Updated', id: req.params.id, status });
        }
    );
});

module.exports = router;
