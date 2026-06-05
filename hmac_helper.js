/**
 * HMAC-SHA256 signing helper for HOBO Auto-Recovery.
 * Mirrors the pattern from fivem-hobocad-script/hmac_helper.js.
 *
 * Usage from Lua (server-side only):
 *   local sig, ts = exports['hobo-auto-recovery']:hmacSign(jsonBody)
 */

const crypto = require('crypto');

function getSecret() {
  return GetConvar('HOBOCAD_HMAC_SECRET', '') || GetConvar('hobocad_hmac_secret', '');
}

exports('hmacSign', (jsonBody) => {
  const secret = getSecret();
  if (!secret) {
    console.log('[HOBO Auto-Recovery] WARNING: HOBOCAD_HMAC_SECRET convar not set — CAD sync disabled');
    return ['', '0'];
  }

  const timestamp = Math.floor(Date.now() / 1000).toString();
  const signature = crypto
    .createHmac('sha256', secret)
    .update(timestamp + ':' + jsonBody)
    .digest('hex');

  return [signature, timestamp];
});
