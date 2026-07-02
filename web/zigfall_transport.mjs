// SPDX-License-Identifier: GPL-3.0-or-later

import { joinRoom, selfId } from "./vendor/trystero-nostr.bundle.mjs";

const MaxPacketSize = 512;
// Bounded inbound backlog for the Zig poll bridge. Zig may emit roughly one
// small runtime packet per sampled frame; browser scheduling can dispatch
// callbacks in bursts. Keep the cap finite while leaving several seconds of
// 60 Hz drain headroom.
const MaxQueuedPackets = 256;
const MaxRoomIdLength = 128;
const RetiringSelectedPeerDrainMs = 2000;
const ProtocolVersion = 2;
const ProfilePacketType = 8;
const AppId = "zigfall-trystero-v2";
const TrysteroRelayUrls = Object.freeze([
  "wss://nostr.sathoarder.com",
  "wss://nostr.vulpem.com",
  "wss://relay.libernet.app",
  "wss://nostr.data.haus",
  "wss://strfry.shock.network",
]);
const PacketActionName = "pkt";
const noop = () => {};

const Status = Object.freeze({
  unavailable: 0,
  missingJs: 1,
  disconnected: 2,
  connecting: 3,
  connected: 4,
  busy: 5,
});

const ErrorCode = Object.freeze({
  none: 0,
  missingJs: 1,
  unavailable: 2,
  badRoom: 3,
  joinFailed: 4,
  notConnected: 5,
  noPeer: 6,
  packetTooLarge: 7,
  queueFull: 8,
  sendFailed: 9,
  bufferTooSmall: 10,
  busy: 11,
});

function validateRoomId(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > MaxRoomIdLength) return null;
  if (!/^[A-Za-z0-9._~-]+$/.test(trimmed)) return null;
  return trimmed;
}

function errorMessage(err) {
  return err && err.message ? err.message : err;
}

function createZigfallTransport({ joinRoomImpl = joinRoom, selfIdValue = selfId, nowImpl = () => Date.now() } = {}) {
  let room = null;
  let packetAction = null;
  let roomId = "";
  let peers = new Set();
  let selectedPeerId = null;
  let retiringSelectedPeer = null;
  let hasSelectedPeerOnce = false;
  let incoming = [];
  let currentStatus = Status.disconnected;
  let lastError = ErrorCode.none;
  let lastErrorMessage = "";
  let healthError = ErrorCode.none;
  let healthErrorMessage = "";
  let connectionGeneration = 0;

  function setStatus(status) {
    currentStatus = status;
  }

  function isReceiveFatalHealthError(code) {
    return code === ErrorCode.packetTooLarge || code === ErrorCode.queueFull;
  }

  function isFatalHealthError(code) {
    return isReceiveFatalHealthError(code) || code === ErrorCode.sendFailed;
  }

  function shouldLatchHealthError(code) {
    if (!isFatalHealthError(code)) return false;
    if (healthError === ErrorCode.none) return true;
    return healthError === ErrorCode.sendFailed && isReceiveFatalHealthError(code);
  }

  function setError(code, message = "") {
    const text = String(message || "");
    lastError = code;
    lastErrorMessage = text;
    if (shouldLatchHealthError(code)) {
      healthError = code;
      healthErrorMessage = text;
    }
    return code;
  }

  function clearError() {
    lastError = ErrorCode.none;
    lastErrorMessage = "";
  }

  function clearAllErrors() {
    clearError();
    healthError = ErrorCode.none;
    healthErrorMessage = "";
  }

  function hasSelectedPeer() {
    return selectedPeerId !== null && peers.has(selectedPeerId);
  }

  function nowMs() {
    const value = Number(nowImpl());
    return Number.isFinite(value) ? value : Date.now();
  }

  function pruneRetiringSelectedPeer() {
    if (!retiringSelectedPeer) return;
    if (retiringSelectedPeer.generation !== connectionGeneration || nowMs() > retiringSelectedPeer.expiresAt) {
      retiringSelectedPeer = null;
    }
  }

  function beginRetiringSelectedPeerDrain(peerId, generation) {
    retiringSelectedPeer = {
      peerId,
      generation,
      expiresAt: nowMs() + RetiringSelectedPeerDrainMs,
    };
  }

  function isRetiringSelectedMessagePeer(peerId) {
    pruneRetiringSelectedPeer();
    return retiringSelectedPeer !== null &&
      retiringSelectedPeer.generation === connectionGeneration &&
      typeof peerId === "string" &&
      peerId === retiringSelectedPeer.peerId;
  }

  function extraPeerCount() {
    return Math.max(0, peers.size - (hasSelectedPeer() ? 1 : 0));
  }

  function updateConnectedStatus() {
    if (!room) {
      setStatus(Status.disconnected);
    } else if (extraPeerCount() > 0) {
      setStatus(Status.busy);
    } else if (hasSelectedPeer()) {
      setStatus(Status.connected);
    } else {
      setStatus(Status.connecting);
    }
  }

  function isProfilePacketView(view) {
    return view.byteLength >= 2 && view[0] === ProtocolVersion && view[1] === ProfilePacketType;
  }

  function readOpaquePacketBytes(packet, { recordError = true, ignoreOversizedProfile = false } = {}) {
    const fail = (code, message) => {
      if (recordError) setError(code, message);
      return { bytes: null, code };
    };

    let view;
    if (packet instanceof ArrayBuffer) {
      view = new Uint8Array(packet);
    } else if (ArrayBuffer.isView(packet)) {
      view = new Uint8Array(packet.buffer, packet.byteOffset, packet.byteLength);
    } else {
      return fail(ErrorCode.sendFailed, "packet must be an ArrayBuffer or ArrayBuffer view");
    }

    if (view.byteLength === 0) {
      return fail(ErrorCode.sendFailed, "packet is empty");
    }
    if (view.byteLength > MaxPacketSize) {
      if (ignoreOversizedProfile && isProfilePacketView(view)) return { bytes: null, code: ErrorCode.none };
      return fail(ErrorCode.packetTooLarge, `packet is ${view.byteLength} bytes; max is ${MaxPacketSize}`);
    }

    // Copy so async Trystero sends never retain a view into WASM memory or caller-owned buffers.
    return { bytes: new Uint8Array(view), code: ErrorCode.none };
  }

  function toOpaquePacketBytes(packet, options = {}) {
    return readOpaquePacketBytes(packet, options).bytes;
  }

  function isSelectedMessagePeer(peerId) {
    return (typeof peerId === "string" && peerId === selectedPeerId && peers.has(peerId)) || isRetiringSelectedMessagePeer(peerId);
  }

  function queueIncomingPacket(packet, generation, peerId) {
    if (generation !== connectionGeneration) return;

    if (!isSelectedMessagePeer(peerId)) {
      if (selectedPeerId === null && peers.size === 0 && hasSelectedPeerOnce) {
        setError(ErrorCode.noPeer, peerId ? "dropped packet from departed peer" : "dropped packet without peer id after peer left");
      } else {
        setError(ErrorCode.busy, peerId ? "dropped packet from non-selected peer" : "dropped packet without peer id");
      }
      updateConnectedStatus();
      return;
    }

    const bytes = toOpaquePacketBytes(packet, { ignoreOversizedProfile: true });
    if (!bytes) return;

    if (isProfilePacketView(bytes)) {
      const existingProfileIndex = incoming.findIndex(isProfilePacketView);
      if (existingProfileIndex !== -1) {
        incoming[existingProfileIndex] = bytes;
        return;
      }
    }

    if (incoming.length >= MaxQueuedPackets) {
      const existingProfileIndex = incoming.findIndex(isProfilePacketView);
      if (existingProfileIndex !== -1) {
        incoming.splice(existingProfileIndex, 1);
      } else {
        if (isProfilePacketView(bytes)) return;
        setError(ErrorCode.queueFull, `incoming queue full (${MaxQueuedPackets} packets)`);
        return;
      }
    }

    incoming.push(bytes);
  }

  function disconnect() {
    connectionGeneration += 1;

    const oldRoom = room;
    const oldPacketAction = packetAction;
    if (oldPacketAction) {
      // Trystero's public action wrapper buffers completed messages when
      // onMessage is null. Keep a no-op handler on the retiring action so late
      // data-channel messages during async leave/failure are drained instead of
      // reopening Trystero's unbounded pendingMessages array.
      oldPacketAction.onMessage = noop;
    }
    if (oldRoom) {
      oldRoom.onPeerJoin = null;
      oldRoom.onPeerLeave = null;
      try {
        Promise.resolve(oldRoom.leave()).catch((err) => {
          console.warn("[ZigfallTransport] room.leave failed", err);
        });
      } catch (err) {
        console.warn("[ZigfallTransport] room.leave failed", err);
      }
    }

    room = null;
    packetAction = null;
    roomId = "";
    peers = new Set();
    selectedPeerId = null;
    retiringSelectedPeer = null;
    hasSelectedPeerOnce = false;
    incoming = [];
    setStatus(Status.disconnected);
    clearAllErrors();
  }

  function connect(nextRoomId) {
    const validatedRoomId = validateRoomId(nextRoomId);
    if (!validatedRoomId) {
      return setError(ErrorCode.badRoom, "room id must be 1..128 URL-safe characters");
    }

    if (room && roomId === validatedRoomId) {
      clearError();
      updateConnectedStatus();
      return ErrorCode.none;
    }

    disconnect();
    setStatus(Status.connecting);

    try {
      const generation = connectionGeneration;
      const nextRoom = joinRoomImpl({ appId: AppId, relayConfig: { urls: TrysteroRelayUrls } }, validatedRoomId);
      const nextPacketAction = nextRoom.makeAction(PacketActionName);

      room = nextRoom;
      roomId = validatedRoomId;
      packetAction = nextPacketAction;
      packetAction.onMessage = (packet, context = {}) => queueIncomingPacket(packet, generation, context.peerId);
      room.onPeerJoin = (peerId) => {
        if (generation !== connectionGeneration) return;
        const hadSelectedPeer = hasSelectedPeer();
        peers.add(peerId);
        if (!hasSelectedPeerOnce) {
          selectedPeerId = peerId;
          retiringSelectedPeer = null;
          hasSelectedPeerOnce = true;
        } else if (peerId !== selectedPeerId) {
          setError(ErrorCode.busy, `room already has selected peer ${selectedPeerId ?? "(left)"}; ignoring ${peerId}`);
        }
        if (!hadSelectedPeer && peerId === selectedPeerId) clearError();
        updateConnectedStatus();
      };
      room.onPeerLeave = (peerId) => {
        if (generation !== connectionGeneration) return;
        const wasSelected = peerId === selectedPeerId;
        peers.delete(peerId);
        if (wasSelected) {
          beginRetiringSelectedPeerDrain(peerId, generation);
          selectedPeerId = null;
          // Keep already-queued selected-peer packets available for Zig to poll
          // before it observes noPeer, and keep accepting same-generation final
          // packets from this retiring peer for a short bounded window; Trystero
          // can report leave before dispatching the peer's final data-channel message.
          setError(ErrorCode.noPeer, "selected peer left room");
        } else if (lastError === ErrorCode.busy && extraPeerCount() === 0) {
          if (selectedPeerId === null && hasSelectedPeerOnce) {
            setError(ErrorCode.noPeer, "selected peer left room");
          } else {
            clearError();
          }
        }
        updateConnectedStatus();
      };
      clearError();
      updateConnectedStatus();
      return ErrorCode.none;
    } catch (err) {
      disconnect();
      return setError(ErrorCode.joinFailed, errorMessage(err));
    }
  }

  function sendInternal(packet, { bestEffort = false } = {}) {
    const { bytes, code } = readOpaquePacketBytes(packet, { recordError: !bestEffort });
    if (!bytes) return code;

    if (!room || !packetAction) {
      return bestEffort ? ErrorCode.notConnected : setError(ErrorCode.notConnected, "not connected to a room");
    }
    if (!hasSelectedPeer()) {
      return bestEffort ? ErrorCode.noPeer : setError(ErrorCode.noPeer, "no selected peer in room");
    }

    const generation = connectionGeneration;
    const action = packetAction;
    const targetPeerId = selectedPeerId;
    action.send(bytes, { target: targetPeerId }).catch((err) => {
      if (generation !== connectionGeneration || packetAction !== action) return;
      if (bestEffort) {
        console.warn("[ZigfallTransport] best-effort send failed", err);
        return;
      }
      setError(ErrorCode.sendFailed, errorMessage(err));
      console.warn("[ZigfallTransport] send failed", err);
    });
    return ErrorCode.none;
  }

  function send(packet) {
    return sendInternal(packet);
  }

  function sendBestEffort(packet) {
    return sendInternal(packet, { bestEffort: true });
  }

  function poll() {
    return incoming.shift() ?? null;
  }

  function pollInto(heapU8, ptr, capacity) {
    const packet = incoming[0];
    if (!packet) return 0;
    if (packet.byteLength > capacity) {
      setError(ErrorCode.bufferTooSmall, `poll buffer is ${capacity} bytes; packet is ${packet.byteLength} bytes`);
      return -ErrorCode.bufferTooSmall;
    }

    heapU8.set(packet, ptr);
    incoming.shift();
    return packet.byteLength;
  }

  function statusCode() {
    updateConnectedStatus();
    return currentStatus;
  }

  function statusName(code = statusCode()) {
    return Object.keys(Status).find((key) => Status[key] === code) ?? "unknown";
  }

  function errorName(code = lastError) {
    return Object.keys(ErrorCode).find((key) => ErrorCode[key] === code) ?? "unknown";
  }

  return Object.freeze({
    MaxPacketSize,
    MaxQueuedPackets,
    MaxRoomIdLength,
    RetiringSelectedPeerDrainMs,
    ProtocolVersion,
    ProfilePacketType,
    AppId,
    PacketActionName,
    Status,
    ErrorCode,
    selfId: selfIdValue,
    connect,
    disconnect,
    send,
    sendBestEffort,
    poll,
    pollInto,
    statusCode,
    statusName,
    errorCode: () => lastError,
    errorName,
    errorMessage: () => lastErrorMessage,
    healthErrorCode: () => healthError,
    healthErrorName: () => errorName(healthError),
    healthErrorMessage: () => healthErrorMessage,
    peerCount: () => peers.size,
    peerIds: () => Array.from(peers),
    selectedPeerId: () => selectedPeerId,
    hadPeer: () => hasSelectedPeerOnce,
    extraPeerCount,
    queuedPacketCount: () => incoming.length,
    roomId: () => roomId,
  });
}

const api = createZigfallTransport();

globalThis.ZigfallTransport = api;

export { api as ZigfallTransport, AppId, ErrorCode, PacketActionName, ProfilePacketType, ProtocolVersion, Status, TrysteroRelayUrls, createZigfallTransport };
