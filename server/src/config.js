function refuseInvalidConfiguration() {
  console.error('[server] startup refused (code=invalid_configuration).');
  process.exit(1);
}

function integerEnvironmentValue(
  name,
  defaultValue,
  { min = 1, max = Number.MAX_SAFE_INTEGER } = {},
) {
  const raw = process.env[name];
  const value = raw == null || raw === '' ? defaultValue : Number(raw);
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    refuseInvalidConfiguration();
  }
  return value;
}

function optionalSecretEnvironmentValue(
  name,
  { minBytes = 32, maxBytes = 4096 } = {},
) {
  const value = String(process.env[name] || '').trim();
  const byteLength = Buffer.byteLength(value, 'utf8');
  if (
    value &&
    (byteLength < minBytes || byteLength > maxBytes)
  ) {
    refuseInvalidConfiguration();
  }
  return value;
}

module.exports = {
  integerEnvironmentValue,
  optionalSecretEnvironmentValue,
};
