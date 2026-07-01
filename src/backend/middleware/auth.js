const crypto = require("crypto");

const failedAttempts = new Map(); // IP → { count, resetAt }
const AUTH_MAX_ATTEMPTS = 5;
const AUTH_WINDOW_MS = 60 * 1000;

function trackFailure(ip, now) {
  const entry = failedAttempts.get(ip);
  if (!entry || now >= entry.resetAt) {
    failedAttempts.set(ip, { count: 1, resetAt: now + AUTH_WINDOW_MS });
  } else {
    entry.count++;
  }
}

const requireAuth = (req, res, next) => {
  const ip = req.ip || req.socket.remoteAddress || "unknown";
  const now = Date.now();

  // Rate-limit failed auth attempts only
  const entry = failedAttempts.get(ip);
  if (entry && now < entry.resetAt && entry.count >= AUTH_MAX_ATTEMPTS) {
    return res
      .status(429)
      .json({ message: "Too many requests. Please try again later." });
  }

  const header = req.headers.authorization;
  const expected = "Bearer " + process.env.API_TOKEN;

  if (!header || header.length !== expected.length) {
    trackFailure(ip, now);
    return res.status(401).json({ message: "Unauthorized" });
  }

  if (!crypto.timingSafeEqual(Buffer.from(header), Buffer.from(expected))) {
    trackFailure(ip, now);
    return res.status(401).json({ message: "Unauthorized" });
  }

  // periodic cleanup of stale entries via setInterval if memory grows
  next();
};

module.exports = { requireAuth };
