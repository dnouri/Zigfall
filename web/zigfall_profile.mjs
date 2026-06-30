// SPDX-License-Identifier: GPL-3.0-or-later

const StorageKey = "zigfall.profile.v1";
const ProfileVersion = 1;
const DefaultNickname = "Player";
const AnonymousPlayerId = "anonymous";
const MaxNicknameLength = 24;
const MaxPlayerIdLength = 64;
const MaxSerializedCardBytes = 256;
const MinRating = 0;
const MaxRating = 4000;
const DefaultRating = 1000;
const KFactor = 32;
const FallbackRandomBytes = 16;
const PlayerIdPattern = /^[A-Za-z0-9._-]+$/;
const HexAlphabet = "0123456789abcdef";

const Status = Object.freeze({
  unavailable: 0,
  missingJs: 1,
  ready: 2,
  memoryOnly: 3,
  storageError: 4,
  cryptoUnavailable: 5,
});

const ErrorCode = Object.freeze({
  none: 0,
  missingJs: 1,
  unavailable: 2,
  bufferTooSmall: 3,
  storageUnavailable: 4,
  storageFailed: 5,
  cryptoUnavailable: 6,
  badNickname: 7,
  badResult: 8,
  badRating: 9,
  profileTooLarge: 10,
});

const ProfileResult = Object.freeze({
  win: 1,
  loss: 2,
  draw: 3,
});

class ZigfallProfileError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "ZigfallProfileError";
    this.code = code;
  }
}

function profileError(code, message) {
  return new ZigfallProfileError(code, message);
}

function errorMessage(err) {
  return err && err.message ? err.message : String(err ?? "unknown error");
}

function defaultStorage() {
  try {
    return globalThis.localStorage ?? null;
  } catch (err) {
    throw profileError(ErrorCode.storageUnavailable, `localStorage is unavailable: ${errorMessage(err)}`);
  }
}

function defaultCrypto() {
  try {
    return globalThis.crypto ?? null;
  } catch {
    return null;
  }
}

function validatePlayerId(value) {
  if (typeof value !== "string") return null;
  if (value.length === 0 || value.length > MaxPlayerIdLength) return null;
  if (!PlayerIdPattern.test(value)) return null;
  return value;
}

function isBidiControl(codePoint) {
  return (codePoint >= 0x202a && codePoint <= 0x202e) || (codePoint >= 0x2066 && codePoint <= 0x2069);
}

function isControl(codePoint) {
  return (codePoint >= 0x00 && codePoint <= 0x1f) || (codePoint >= 0x7f && codePoint <= 0x9f);
}

function isAllowedNicknameChar(char, codePoint) {
  if (char === " " || char === "." || char === "_" || char === "-") return true;
  return (codePoint >= 0x30 && codePoint <= 0x39) ||
    (codePoint >= 0x41 && codePoint <= 0x5a) ||
    (codePoint >= 0x61 && codePoint <= 0x7a);
}

function sanitizeNickname(value) {
  const input = String(value ?? "");
  let output = "";
  let pendingSpace = false;

  for (const char of input) {
    const codePoint = char.codePointAt(0);
    if (/\s/u.test(char)) {
      if (output.length > 0) pendingSpace = true;
      continue;
    }
    if (isBidiControl(codePoint) || isControl(codePoint)) continue;
    if (!isAllowedNicknameChar(char, codePoint)) continue;

    if (pendingSpace) {
      if (output.length >= MaxNicknameLength) break;
      output += " ";
      pendingSpace = false;
    }
    if (output.length >= MaxNicknameLength) break;
    output += char;
  }

  output = output.trim();
  return output.length > 0 ? output : DefaultNickname;
}

function clampRating(value) {
  if (!Number.isFinite(value)) return DefaultRating;
  const integer = Math.trunc(value);
  if (integer <= MinRating) return MinRating;
  if (integer >= MaxRating) return MaxRating;
  return integer;
}

function normalizeStat(value) {
  if (!Number.isFinite(value)) return 0;
  const integer = Math.trunc(value);
  if (integer <= 0) return 0;
  return Math.min(integer, 0xffffffff);
}

function incrementStat(value) {
  return Math.min(normalizeStat(value) + 1, 0xffffffff);
}

function expectedScore(rating, opponentRating) {
  return 1 / (1 + (10 ** ((opponentRating - rating) / 400)));
}

function resultScore(result) {
  switch (normalizeResult(result)) {
    case ProfileResult.win:
      return 1;
    case ProfileResult.loss:
      return 0;
    case ProfileResult.draw:
      return 0.5;
    default:
      throw profileError(ErrorCode.badResult, "unknown result");
  }
}

function ratingDelta(rating, opponentRating, result) {
  return Math.round(KFactor * (resultScore(result) - expectedScore(rating, opponentRating)));
}

function updatedRating(rating, opponentRating, result) {
  return clampRating(rating + ratingDelta(rating, opponentRating, result));
}

function normalizeResult(value) {
  if (value === ProfileResult.win || value === "win") return ProfileResult.win;
  if (value === ProfileResult.loss || value === "loss") return ProfileResult.loss;
  if (value === ProfileResult.draw || value === "draw") return ProfileResult.draw;
  throw profileError(ErrorCode.badResult, "result must be win, loss, or draw");
}

function normalizeOpponentRating(value) {
  if (!Number.isFinite(value)) throw profileError(ErrorCode.badRating, "opponent rating must be a finite number");
  return clampRating(value);
}

function hexByte(value) {
  return HexAlphabet[(value >>> 4) & 0x0f] + HexAlphabet[value & 0x0f];
}

function generatePlayerId(cryptoImpl) {
  if (cryptoImpl && typeof cryptoImpl.randomUUID === "function") {
    try {
      const id = validatePlayerId(String(cryptoImpl.randomUUID()));
      if (id) return id;
    } catch {
      // Fall through to getRandomValues below when available.
    }
  }

  if (cryptoImpl && typeof cryptoImpl.getRandomValues === "function") {
    const bytes = new Uint8Array(FallbackRandomBytes);
    cryptoImpl.getRandomValues(bytes);
    let id = "p_";
    for (const byte of bytes) id += hexByte(byte);
    const validated = validatePlayerId(id);
    if (validated) return validated;
  }

  throw profileError(ErrorCode.cryptoUnavailable, "crypto.randomUUID/getRandomValues is unavailable for a persistent player ID");
}

function baseProfile(playerId) {
  return {
    version: ProfileVersion,
    playerId,
    nickname: DefaultNickname,
    rating: DefaultRating,
    wins: 0,
    losses: 0,
    draws: 0,
  };
}

function anonymousProfile() {
  return baseProfile(AnonymousPlayerId);
}

function createFreshProfile(cryptoImpl) {
  return baseProfile(generatePlayerId(cryptoImpl));
}

function normalizeProfile(value) {
  if (!value || typeof value !== "object") throw profileError(ErrorCode.unavailable, "stored profile is not an object");
  const playerId = validatePlayerId(value.playerId);
  if (!playerId) throw profileError(ErrorCode.unavailable, "stored profile has an invalid player ID");
  return {
    version: ProfileVersion,
    playerId,
    nickname: sanitizeNickname(value.nickname),
    rating: clampRating(value.rating),
    wins: normalizeStat(value.wins),
    losses: normalizeStat(value.losses),
    draws: normalizeStat(value.draws),
  };
}

function cardFromProfile(profile) {
  return Object.freeze({
    playerId: profile.playerId,
    nickname: profile.nickname,
    rating: profile.rating,
    wins: profile.wins,
    losses: profile.losses,
    draws: profile.draws,
  });
}

function serializeProfileCard(profile) {
  const normalized = normalizeProfile(profile);
  const text = JSON.stringify({
    version: ProfileVersion,
    playerId: normalized.playerId,
    nickname: normalized.nickname,
    rating: normalized.rating,
    wins: normalized.wins,
    losses: normalized.losses,
    draws: normalized.draws,
  });
  if (text.length > MaxSerializedCardBytes) {
    throw profileError(ErrorCode.profileTooLarge, `profile card is ${text.length} bytes; max is ${MaxSerializedCardBytes}`);
  }
  return text;
}

function parseStoredProfile(text) {
  let parsed;
  try {
    parsed = JSON.parse(String(text));
  } catch (err) {
    throw profileError(ErrorCode.unavailable, `stored profile JSON is malformed: ${errorMessage(err)}`);
  }
  return normalizeProfile(parsed);
}

function createZigfallProfile({
  storageImpl = undefined,
  cryptoImpl = undefined,
} = {}) {
  let status = Status.ready;
  let lastErrorMessage = "";
  let storage = null;
  let profile = null;

  const cryptoSource = cryptoImpl === undefined ? defaultCrypto() : cryptoImpl;

  function setStatus(nextStatus, message = "") {
    status = nextStatus;
    lastErrorMessage = String(message || "");
  }

  function markMemoryOnly(message) {
    storage = null;
    setStatus(Status.memoryOnly, message);
  }

  function saveCurrentProfile() {
    if (!storage) return false;
    try {
      const serialized = serializeProfileCard(profile);
      storage.setItem(StorageKey, serialized);
      if (storage.getItem(StorageKey) !== serialized) {
        throw profileError(ErrorCode.storageFailed, "localStorage profile save verification failed");
      }
      return true;
    } catch (err) {
      markMemoryOnly(`localStorage profile save failed: ${errorMessage(err)}`);
      return false;
    }
  }

  try {
    storage = storageImpl === undefined ? defaultStorage() : storageImpl;
  } catch (err) {
    markMemoryOnly(errorMessage(err));
  }

  if (!storage) {
    if (status === Status.ready) markMemoryOnly("localStorage is unavailable; using a memory-only profile");
  } else if (typeof storage.getItem !== "function" || typeof storage.setItem !== "function") {
    markMemoryOnly("localStorage-compatible getItem/setItem methods are unavailable");
  }

  if (storage) {
    try {
      const stored = storage.getItem(StorageKey);
      if (stored !== null && stored !== undefined) {
        profile = parseStoredProfile(stored);
        saveCurrentProfile();
      }
    } catch (err) {
      lastErrorMessage = `stored profile was reset: ${errorMessage(err)}`;
      profile = null;
    }
  }

  if (!profile) {
    try {
      profile = createFreshProfile(cryptoSource);
    } catch (err) {
      profile = anonymousProfile();
      storage = null;
      setStatus(Status.cryptoUnavailable, `${errorMessage(err)}; using an anonymous memory-only profile`);
    }

    if (storage) {
      const resetMessage = lastErrorMessage;
      if (saveCurrentProfile()) {
        status = Status.ready;
        lastErrorMessage = resetMessage;
      }
    }
  }

  function persistAfterMutation() {
    saveCurrentProfile();
    return cardFromProfile(profile);
  }

  function setNickname(value) {
    profile.nickname = sanitizeNickname(value);
    return persistAfterMutation();
  }

  function applyVerifiedResult(result, opponentRating) {
    const normalizedResult = normalizeResult(result);
    const normalizedOpponentRating = normalizeOpponentRating(opponentRating);
    profile.rating = updatedRating(profile.rating, normalizedOpponentRating, normalizedResult);
    if (normalizedResult === ProfileResult.win) profile.wins = incrementStat(profile.wins);
    else if (normalizedResult === ProfileResult.loss) profile.losses = incrementStat(profile.losses);
    else profile.draws = incrementStat(profile.draws);
    return persistAfterMutation();
  }

  function recordMatchResult({ verified = false, result = null, outcome = null, opponentRating = DefaultRating } = {}) {
    if (verified !== true) return { updated: false, card: cardFromProfile(profile) };
    const nextCard = applyVerifiedResult(result ?? outcome, opponentRating);
    return { updated: true, card: nextCard };
  }

  function statusText(code = status) {
    switch (code) {
      case Status.ready:
        return "ready";
      case Status.memoryOnly:
        return "memory-only";
      case Status.storageError:
        return "storage error";
      case Status.cryptoUnavailable:
        return "crypto unavailable";
      case Status.missingJs:
        return "missing JS";
      case Status.unavailable:
      default:
        return "unavailable";
    }
  }

  function tryApplyVerifiedResult(result, opponentRating) {
    try {
      applyVerifiedResult(result, opponentRating);
      return ErrorCode.none;
    } catch (err) {
      lastErrorMessage = errorMessage(err);
      return err && Number.isInteger(err.code) ? err.code : ErrorCode.unavailable;
    }
  }

  return Object.freeze({
    StorageKey,
    ProfileVersion,
    DefaultNickname,
    AnonymousPlayerId,
    MaxNicknameLength,
    MaxPlayerIdLength,
    MaxSerializedCardBytes,
    MinRating,
    MaxRating,
    DefaultRating,
    KFactor,
    Status,
    ErrorCode,
    ProfileResult,
    card: () => cardFromProfile(profile),
    serializeCard: () => serializeProfileCard(profile),
    statusCode: () => status,
    statusText,
    lastErrorMessage: () => lastErrorMessage,
    setNickname,
    applyVerifiedResult,
    tryApplyVerifiedResult,
    recordMatchResult,
    sanitizeNickname,
    validatePlayerId,
    expectedScore,
    ratingDelta,
    updatedRating,
  });
}

const api = createZigfallProfile();

globalThis.ZigfallProfile = api;

export {
  api as ZigfallProfile,
  AnonymousPlayerId,
  DefaultNickname,
  DefaultRating,
  ErrorCode,
  KFactor,
  MaxNicknameLength,
  MaxPlayerIdLength,
  MaxRating,
  MaxSerializedCardBytes,
  MinRating,
  ProfileResult,
  Status,
  StorageKey,
  createZigfallProfile,
  sanitizeNickname,
  serializeProfileCard,
  validatePlayerId,
};
