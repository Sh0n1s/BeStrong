'use strict';

// BeStrong sample application.
// Sole purpose: prove the sandbox infrastructure end to end via GET /health.
// Response shape is exactly { status, sql, fileshare, insights }; diagnostics
// are short strings only — never stack traces, connection strings, or secrets.

// Application Insights must initialize before other requires it instruments.
// Started ONLY when the connection string app setting is present (it is
// injected by Terraform only when enable_application_insights = true).
let insightsStarted = false;
if (process.env.APPLICATIONINSIGHTS_CONNECTION_STRING) {
  try {
    const appInsights = require('applicationinsights');
    appInsights.setup(process.env.APPLICATIONINSIGHTS_CONNECTION_STRING).start();
    insightsStarted = true;
  } catch (err) {
    // Log locally (App Service console logs); /health will report the failure.
    console.error('Application Insights SDK failed to start:', err.code || err.name || 'unknown');
  }
}

const path = require('path');
const fs = require('fs/promises');
const crypto = require('crypto');
const express = require('express');
const sql = require('mssql');

const PORT = process.env.PORT || 8080;
const CHECK_TIMEOUT_MS = 5000;

// Bound any dependency call so one slow component cannot hang /health.
function withTimeout(promise, ms, label) {
  let timer;
  const timeout = new Promise((resolve, reject) => {
    timer = setTimeout(() => {
      const err = new Error(`${label} timed out`);
      err.code = 'ETIMEDOUT';
      reject(err);
    }, ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

// Short, secret-free diagnostic: error code or class name only. Driver
// messages can embed logins or server coordinates, so they are never echoed.
function diagnostic(err) {
  const code = err && (err.code || err.name);
  return code ? `error: ${code}` : 'error: unknown';
}

// SQL check: SELECT 1 over the VNet service-endpoint path, using the
// SQL-auth app settings injected by Terraform.
async function checkSql() {
  const config = {
    server: process.env.SQL_SERVER_FQDN,
    database: process.env.SQL_DATABASE_NAME,
    user: process.env.SQL_ADMIN_LOGIN,
    password: process.env.SQL_ADMIN_PASSWORD,
    connectionTimeout: CHECK_TIMEOUT_MS,
    requestTimeout: CHECK_TIMEOUT_MS,
    pool: { max: 1, min: 0 },
    options: { encrypt: true, trustServerCertificate: false }
  };
  if (!config.server || !config.database || !config.user || !config.password) {
    return 'error: sql settings missing';
  }
  let pool;
  try {
    pool = new sql.ConnectionPool(config);
    await withTimeout(pool.connect(), CHECK_TIMEOUT_MS + 500, 'sql connect');
    const result = await withTimeout(pool.request().query('SELECT 1 AS ok'), CHECK_TIMEOUT_MS, 'sql query');
    if (!result.recordset || result.recordset.length !== 1 || result.recordset[0].ok !== 1) {
      return 'error: unexpected query result';
    }
    return 'ok';
  } catch (err) {
    return diagnostic(err);
  } finally {
    if (pool) {
      pool.close().catch(() => {});
    }
  }
}

// File share check: write, read back, and delete a probe file on the Azure
// Files share (FILES_MOUNT_PATH, mounted by the App Service storage_account block).
async function checkFileshare() {
  const mountPath = process.env.FILES_MOUNT_PATH;
  if (!mountPath) {
    return 'error: mount path setting missing';
  }
  const probeFile = path.join(mountPath, `healthprobe-${crypto.randomBytes(8).toString('hex')}.tmp`);
  const payload = `bestrong-health-probe ${Date.now()}`;
  try {
    await withTimeout(
      (async () => {
        await fs.writeFile(probeFile, payload, 'utf8');
        const readBack = await fs.readFile(probeFile, 'utf8');
        if (readBack !== payload) {
          const err = new Error('probe read mismatch');
          err.code = 'EREADMISMATCH';
          throw err;
        }
        await fs.unlink(probeFile);
      })(),
      CHECK_TIMEOUT_MS,
      'fileshare probe'
    );
    return 'ok';
  } catch (err) {
    fs.unlink(probeFile).catch(() => {}); // best-effort cleanup
    return diagnostic(err);
  }
}

// Insights check: "ok" only if the SDK actually started; "disabled" is
// legitimate when the connection string is absent (enable_application_insights = false).
function checkInsights() {
  if (!process.env.APPLICATIONINSIGHTS_CONNECTION_STRING) {
    return 'disabled';
  }
  return insightsStarted ? 'ok' : 'error: sdk failed to start';
}

const app = express();
app.disable('x-powered-by');

// The only route, by design: no auth, no business logic — this app exists
// solely to verify the infrastructure.
app.get('/health', async (req, res) => {
  const [sqlStatus, fileshareStatus] = await Promise.all([checkSql(), checkFileshare()]);
  const insightsStatus = checkInsights();
  const healthy =
    sqlStatus === 'ok' &&
    fileshareStatus === 'ok' &&
    (insightsStatus === 'ok' || insightsStatus === 'disabled');
  res.status(healthy ? 200 : 503).json({
    status: healthy ? 'ok' : 'error',
    sql: sqlStatus,
    fileshare: fileshareStatus,
    insights: insightsStatus
  });
});

const server = app.listen(PORT, () => {
  console.log(`bestrong-sample listening on port ${PORT}`);
});

// Clean shutdown so App Service container restarts (e.g. after a deploy) are fast.
['SIGTERM', 'SIGINT'].forEach((signal) => {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  });
});
