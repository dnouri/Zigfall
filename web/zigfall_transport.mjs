// SPDX-License-Identifier: GPL-3.0-or-later

import { joinRoom, selfId } from "./vendor/trystero-nostr.bundle.mjs";

const MaxPacketSize = 512;
const MaxQueuedPackets = 64;
const MaxRoomIdLength = 128;
const AppId = "zigfall-trystero-v1";
const PacketActionName = "pkt";

const Status = Object.freeze({
  unavailable: 0,
  missingJs: 1,
  disconnected: 2,
  connecting: 3,
  connected: 4,
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
});

let room = null;
let packetAction = null;
let roomId = "";
let peers = new Set();
let incoming = [];
let currentStatus = Status.disconnected;
let lastError = ErrorCode.none;
let lastErrorMessage = "";
let connectionGeneration = 0;

function setStatus(status) {
  currentStatus = status;
}

function setError(code, message = "") {
  lastError = code;
  lastErrorMessage = String(message || "");
  return code;
}

function clearError() {
  lastError = ErrorCode.none;
  lastErrorMessage = "";
}

function validateRoomId(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > MaxRoomIdLength) return null;
  if (!/^[A-Za-z0-9._~-]+$/.test(trimmed)) return null;
  return trimmed;
}

function toOpaquePacketBytes(packet) {
  let view;
  if (packet instanceof ArrayBuffer) {
    view = new Uint8Array(packet);
  } else if (ArrayBuffer.isView(packet)) {
    view = new Uint8Array(packet.buffer, packet.byteOffset, packet.byteLength);
  } else {
    setError(ErrorCode.sendFailed, "packet must be an ArrayBuffer or ArrayBuffer view");
    return null;
  }

  if (view.byteLength === 0) {
    setError(ErrorCode.sendFailed, "packet is empty");
    return null;
  }
  if (view.byteLength > MaxPacketSize) {
    setError(ErrorCode.packetTooLarge, `packet is ${view.byteLength} bytes; max is ${MaxPacketSize}`);
    return null;
  }

  // Copy so async Trystero sends never retain a view into WASM memory or caller-owned buffers.
  return new Uint8Array(view);
}

function queueIncomingPacket(packet, generation) {
  if (generation !== connectionGeneration) return;

  const bytes = toOpaquePacketBytes(packet);
  if (!bytes) return;

  if (incoming.length >= MaxQueuedPackets) {
    setError(ErrorCode.queueFull, `incoming queue full (${MaxQueuedPackets} packets)`);
    return;
  }

  incoming.push(bytes);
}

function updateConnectedStatus() {
  setStatus(room ? (peers.size > 0 ? Status.connected : Status.connecting) : Status.disconnected);
}

function disconnect() {
  connectionGeneration += 1;

  const oldRoom = room;
  const oldPacketAction = packetAction;
  if (oldPacketAction) oldPacketAction.onMessage = null;
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
  incoming = [];
  setStatus(Status.disconnected);
  clearError();
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
    room = joinRoom({ appId: AppId }, validatedRoomId);
    roomId = validatedRoomId;
    packetAction = room.makeAction(PacketActionName);
    packetAction.onMessage = (packet) => queueIncomingPacket(packet, generation);
    room.onPeerJoin = (peerId) => {
      if (generation !== connectionGeneration) return;
      peers.add(peerId);
      updateConnectedStatus();
    };
    room.onPeerLeave = (peerId) => {
      if (generation !== connectionGeneration) return;
      peers.delete(peerId);
      updateConnectedStatus();
    };
    clearError();
    updateConnectedStatus();
    return ErrorCode.none;
  } catch (err) {
    disconnect();
    return setError(ErrorCode.joinFailed, err && err.message ? err.message : err);
  }
}

function send(packet) {
  const bytes = toOpaquePacketBytes(packet);
  if (!bytes) return lastError;

  if (!room || !packetAction) return setError(ErrorCode.notConnected, "not connected to a room");
  if (peers.size === 0) return setError(ErrorCode.noPeer, "no peer in room");

  packetAction.send(bytes).catch((err) => {
    setError(ErrorCode.sendFailed, err && err.message ? err.message : err);
    console.warn("[ZigfallTransport] send failed", err);
  });
  return ErrorCode.none;
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

const api = Object.freeze({
  MaxPacketSize,
  MaxQueuedPackets,
  MaxRoomIdLength,
  Status,
  ErrorCode,
  selfId,
  connect,
  disconnect,
  send,
  poll,
  pollInto,
  statusCode,
  statusName,
  errorCode: () => lastError,
  errorName,
  errorMessage: () => lastErrorMessage,
  peerCount: () => peers.size,
  peerIds: () => Array.from(peers),
  queuedPacketCount: () => incoming.length,
  roomId: () => roomId,
});

globalThis.ZigfallTransport = api;

export { api as ZigfallTransport, Status, ErrorCode };
