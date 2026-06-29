// SPDX-License-Identifier: GPL-3.0-or-later

const MaxRoomIdLength = 128;
const MaxJoinUrlLength = 2048;
const GeneratedRoomRandomBytes = 18;
const RoomIdPattern = /^[A-Za-z0-9._~-]+$/;
const Base64UrlAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

const ErrorCode = Object.freeze({
  none: 0,
  missingJs: 1,
  unavailable: 2,
  badRoom: 3,
  bufferTooSmall: 4,
  randomUnavailable: 5,
  urlTooLong: 6,
  copyUnavailable: 7,
  copyFailed: 8,
});

const CopyStatus = Object.freeze({
  unavailable: 0,
  missingJs: 1,
  idle: 2,
  pending: 3,
  copied: 4,
  fallback: 5,
  failed: 6,
});

class ZigfallInviteError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "ZigfallInviteError";
    this.code = code;
  }
}

function inviteError(code, message) {
  return new ZigfallInviteError(code, message);
}

function errorMessage(err) {
  return err && err.message ? err.message : String(err ?? "unknown error");
}

function validateRoomId(value) {
  if (typeof value !== "string") return null;
  if (value.length === 0 || value.length > MaxRoomIdLength) return null;
  if (!RoomIdPattern.test(value)) return null;
  return value;
}

function locationHref(locationLike) {
  if (!locationLike) return null;
  if (typeof locationLike === "string") return locationLike;
  if (typeof locationLike.href === "string") return locationLike.href;
  return null;
}

function parseUrl(locationLike) {
  const href = locationHref(locationLike);
  if (!href) throw inviteError(ErrorCode.unavailable, "current page URL is unavailable");
  try {
    return new URL(href);
  } catch (err) {
    throw inviteError(ErrorCode.unavailable, `current page URL is invalid: ${errorMessage(err)}`);
  }
}

function encodeBase64Url(bytes) {
  let output = "";
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const triplet = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    output += Base64UrlAlphabet[(triplet >>> 18) & 0x3f];
    output += Base64UrlAlphabet[(triplet >>> 12) & 0x3f];
    output += Base64UrlAlphabet[(triplet >>> 6) & 0x3f];
    output += Base64UrlAlphabet[triplet & 0x3f];
  }

  const remaining = bytes.length - i;
  if (remaining === 1) {
    const value = bytes[i];
    output += Base64UrlAlphabet[(value >>> 2) & 0x3f];
    output += Base64UrlAlphabet[(value << 4) & 0x3f];
  } else if (remaining === 2) {
    const value = (bytes[i] << 8) | bytes[i + 1];
    output += Base64UrlAlphabet[(value >>> 10) & 0x3f];
    output += Base64UrlAlphabet[(value >>> 4) & 0x3f];
    output += Base64UrlAlphabet[(value << 2) & 0x3f];
  }

  return output;
}

function generateRoomId(cryptoImpl) {
  if (!cryptoImpl || typeof cryptoImpl.getRandomValues !== "function") {
    throw inviteError(ErrorCode.randomUnavailable, "crypto.getRandomValues is unavailable");
  }

  const bytes = new Uint8Array(GeneratedRoomRandomBytes);
  cryptoImpl.getRandomValues(bytes);
  const roomId = encodeBase64Url(bytes);
  if (!validateRoomId(roomId)) {
    throw inviteError(ErrorCode.randomUnavailable, "generated room id failed validation");
  }
  return roomId;
}

function copyStatusName(code) {
  return Object.keys(CopyStatus).find((key) => CopyStatus[key] === code) ?? "unknown";
}

function createZigfallInvite({
  cryptoImpl = globalThis.crypto,
  locationImpl = globalThis.location,
  navigatorImpl = globalThis.navigator,
  documentImpl = globalThis.document,
} = {}) {
  let lastCopyStatus = CopyStatus.idle;
  let lastCopyErrorMessage = "";

  function setCopyStatus(status, message = "") {
    lastCopyStatus = status;
    lastCopyErrorMessage = String(message || "");
    return status;
  }

  function readInitialJoinRoom(locationOverride = locationImpl) {
    const href = locationHref(locationOverride);
    if (!href) return { roomId: null, errorCode: ErrorCode.none };

    let url;
    try {
      url = new URL(href);
    } catch (err) {
      return { roomId: null, errorCode: ErrorCode.unavailable, message: errorMessage(err) };
    }

    const rawRoomId = url.searchParams.get("join");
    if (rawRoomId === null) return { roomId: null, errorCode: ErrorCode.none };

    const roomId = validateRoomId(rawRoomId);
    if (!roomId) {
      return { roomId: null, errorCode: ErrorCode.badRoom, message: "join parameter is not a URL-safe room id" };
    }

    return { roomId, errorCode: ErrorCode.none };
  }

  function initialJoinRoom(locationOverride = locationImpl) {
    return readInitialJoinRoom(locationOverride).roomId;
  }

  function createHostRoom() {
    return generateRoomId(cryptoImpl);
  }

  function joinUrl(roomId, locationOverride = locationImpl) {
    const validatedRoomId = validateRoomId(roomId);
    if (!validatedRoomId) throw inviteError(ErrorCode.badRoom, "room id must be 1..128 URL-safe characters");

    const currentUrl = parseUrl(locationOverride);
    const url = new URL(currentUrl.pathname, currentUrl.origin);
    url.searchParams.set("join", validatedRoomId);
    const result = url.toString();
    if (result.length > MaxJoinUrlLength) {
      throw inviteError(ErrorCode.urlTooLong, `join URL is ${result.length} characters; max is ${MaxJoinUrlLength}`);
    }
    return result;
  }

  function fallbackCopyText(text) {
    if (!documentImpl || typeof documentImpl.createElement !== "function" || typeof documentImpl.execCommand !== "function") {
      return false;
    }

    const body = documentImpl.body || documentImpl.documentElement;
    if (!body || typeof body.appendChild !== "function") return false;

    const textArea = documentImpl.createElement("textarea");
    textArea.value = text;
    textArea.setAttribute?.("readonly", "");
    if (textArea.style) {
      textArea.style.position = "fixed";
      textArea.style.left = "-9999px";
      textArea.style.top = "0";
    }

    body.appendChild(textArea);
    try {
      textArea.focus?.();
      textArea.select?.();
      textArea.setSelectionRange?.(0, text.length);
      return documentImpl.execCommand("copy") === true;
    } finally {
      if (typeof body.removeChild === "function") body.removeChild(textArea);
      else textArea.remove?.();
    }
  }

  async function copyText(text) {
    const value = String(text ?? "");
    if (value.length === 0) return setCopyStatus(CopyStatus.failed, "nothing to copy");

    let clipboardError = null;
    const clipboard = navigatorImpl && navigatorImpl.clipboard;
    if (clipboard && typeof clipboard.writeText === "function") {
      try {
        await clipboard.writeText(value);
        return setCopyStatus(CopyStatus.copied);
      } catch (err) {
        clipboardError = err;
      }
    }

    if (fallbackCopyText(value)) return setCopyStatus(CopyStatus.fallback);

    const message = clipboardError ? errorMessage(clipboardError) : "clipboard API is unavailable";
    return setCopyStatus(CopyStatus.failed, message);
  }

  async function copyJoinUrl(roomId, locationOverride = locationImpl) {
    return copyText(joinUrl(roomId, locationOverride));
  }

  function requestCopyText(text) {
    setCopyStatus(CopyStatus.pending);
    Promise.resolve().then(() => copyText(text)).catch((err) => {
      setCopyStatus(CopyStatus.failed, errorMessage(err));
    });
    return ErrorCode.none;
  }

  function requestCopyJoinUrl(roomId, locationOverride = locationImpl) {
    let url;
    try {
      url = joinUrl(roomId, locationOverride);
    } catch (err) {
      return err && Number.isInteger(err.code) ? err.code : ErrorCode.copyFailed;
    }
    return requestCopyText(url);
  }

  return Object.freeze({
    MaxRoomIdLength,
    MaxJoinUrlLength,
    GeneratedRoomRandomBytes,
    ErrorCode,
    CopyStatus,
    validateRoomId,
    readInitialJoinRoom,
    initialJoinRoom,
    createHostRoom,
    joinUrl,
    copyText,
    copyJoinUrl,
    requestCopyText,
    requestCopyJoinUrl,
    copyStatus: () => lastCopyStatus,
    copyStatusName,
    copyErrorMessage: () => lastCopyErrorMessage,
  });
}

const api = createZigfallInvite();

globalThis.ZigfallInvite = api;

export {
  api as ZigfallInvite,
  CopyStatus,
  ErrorCode,
  MaxJoinUrlLength,
  MaxRoomIdLength,
  createZigfallInvite,
  validateRoomId,
};
