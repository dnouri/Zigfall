// SPDX-License-Identifier: GPL-3.0-or-later

(() => {
  const MaxPacketSize = 512;
  const MaxQueuedPackets = 256;
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

  const channelName = "zigfall-browser-test-transport";
  const selfId = `fake-${crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2)}`;
  let channel = null;
  let roomId = "";
  let peers = new Set();
  let selectedPeerId = null;
  let incoming = [];
  let status = Status.disconnected;
  let lastError = ErrorCode.none;
  let lastErrorMessage = "";
  let generation = 0;
  const stats = {
    connects: [],
    sentPackets: [],
    receivedPackets: [],
    dequeuedPackets: 0,
    droppedPackets: 0,
    sendAttempts: 0,
  };

  function nowMs() {
    return Date.now();
  }

  function errorName(code) {
    return Object.keys(ErrorCode).find((key) => ErrorCode[key] === code) ?? "unknown";
  }

  function statusName(code = statusCode()) {
    return Object.keys(Status).find((key) => Status[key] === code) ?? "unknown";
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

  function hasSelectedPeer() {
    return selectedPeerId !== null && peers.has(selectedPeerId);
  }

  function extraPeerCount() {
    return Math.max(0, peers.size - (hasSelectedPeer() ? 1 : 0));
  }

  function updateStatus() {
    if (!channel || !roomId) status = Status.disconnected;
    else if (extraPeerCount() > 0) status = Status.busy;
    else if (hasSelectedPeer()) status = Status.connected;
    else status = Status.connecting;
  }

  function post(message) {
    channel?.postMessage({ ...message, roomId, peerId: selfId, generation });
  }

  function rememberPeer(peerId) {
    if (!peerId || peerId === selfId) return;
    peers.add(peerId);
    if (selectedPeerId === null) {
      selectedPeerId = peerId;
      clearError();
    } else if (selectedPeerId !== peerId) {
      setError(ErrorCode.busy, "extra fake peer joined");
    }
    updateStatus();
  }

  function removePeer(peerId) {
    peers.delete(peerId);
    if (selectedPeerId === peerId) {
      selectedPeerId = null;
      setError(ErrorCode.noPeer, "fake peer left");
    }
    updateStatus();
  }

  function packetBytes(packet) {
    if (packet instanceof ArrayBuffer) return new Uint8Array(packet);
    if (ArrayBuffer.isView(packet)) return new Uint8Array(packet.buffer, packet.byteOffset, packet.byteLength);
    return null;
  }

  function queuePacket(bytes, peerId) {
    if (peerId !== selectedPeerId) {
      stats.droppedPackets += 1;
      setError(ErrorCode.busy, "packet from non-selected fake peer");
      return;
    }
    if (bytes.byteLength > MaxPacketSize) {
      stats.droppedPackets += 1;
      setError(ErrorCode.packetTooLarge, "fake packet too large");
      return;
    }
    if (incoming.length >= MaxQueuedPackets) {
      stats.droppedPackets += 1;
      setError(ErrorCode.queueFull, "fake incoming queue full");
      return;
    }
    incoming.push({ bytes: new Uint8Array(bytes), peerId, queuedAt: nowMs() });
    stats.receivedPackets.push({ length: bytes.byteLength, peerId, at: nowMs() });
  }

  function handleMessage(event) {
    const message = event.data;
    if (!message || message.peerId === selfId || message.roomId !== roomId) return;
    switch (message.type) {
      case "join":
        rememberPeer(message.peerId);
        post({ type: "hello", target: message.peerId });
        break;
      case "hello":
        if (!message.target || message.target === selfId) rememberPeer(message.peerId);
        break;
      case "leave":
        removePeer(message.peerId);
        break;
      case "packet":
        if (!message.target || message.target === selfId) {
          queuePacket(Uint8Array.from(message.bytes ?? []), message.peerId);
        }
        break;
    }
  }

  function connect(nextRoomId) {
    if (typeof nextRoomId !== "string" || nextRoomId.length === 0) {
      return setError(ErrorCode.badRoom, "empty fake room id");
    }
    if (roomId === nextRoomId && channel) {
      updateStatus();
      return ErrorCode.none;
    }

    disconnect();
    generation += 1;
    roomId = nextRoomId;
    channel = new BroadcastChannel(channelName);
    channel.onmessage = handleMessage;
    peers = new Set();
    selectedPeerId = null;
    incoming = [];
    stats.connects.push({ roomId, at: nowMs() });
    status = Status.connecting;
    clearError();
    post({ type: "join" });
    return ErrorCode.none;
  }

  function disconnect() {
    if (channel) {
      post({ type: "leave" });
      channel.close();
    }
    channel = null;
    roomId = "";
    peers = new Set();
    selectedPeerId = null;
    incoming = [];
    status = Status.disconnected;
    clearError();
  }

  function sendInternal(packet, { bestEffort = false } = {}) {
    const fail = (code, message) => bestEffort ? code : setError(code, message);
    const bytes = packetBytes(packet);
    if (!bytes || bytes.byteLength === 0) return fail(ErrorCode.sendFailed, "fake packet is empty");
    if (bytes.byteLength > MaxPacketSize) return fail(ErrorCode.packetTooLarge, "fake packet too large");
    if (!channel || !roomId) return fail(ErrorCode.notConnected, "fake transport not connected");
    if (!hasSelectedPeer()) return fail(ErrorCode.noPeer, "fake transport has no selected peer");
    stats.sendAttempts += 1;
    stats.sentPackets.push({ length: bytes.byteLength, target: selectedPeerId, at: nowMs() });
    post({ type: "packet", target: selectedPeerId, bytes: Array.from(bytes) });
    return ErrorCode.none;
  }

  function send(packet) {
    return sendInternal(packet);
  }

  function sendBestEffort(packet) {
    return sendInternal(packet, { bestEffort: true });
  }

  function poll() {
    const entry = incoming.shift() ?? null;
    if (!entry) return null;
    stats.dequeuedPackets += 1;
    return entry.bytes;
  }

  function pollInto(heapU8, ptr, capacity) {
    const entry = incoming[0];
    if (!entry) return 0;
    if (entry.bytes.byteLength > capacity) return -ErrorCode.bufferTooSmall;
    heapU8.set(entry.bytes, ptr);
    incoming.shift();
    stats.dequeuedPackets += 1;
    return entry.bytes.byteLength;
  }

  function statusCode() {
    updateStatus();
    return status;
  }

  function debugSnapshot() {
    const now = nowMs();
    const oldest = incoming[0] ?? null;
    return {
      fake: true,
      selfId,
      roomId,
      status: statusCode(),
      statusName: statusName(),
      error: { code: lastError, name: errorName(lastError), message: lastErrorMessage },
      peers: { count: peers.size, ids: Array.from(peers), selectedPeerId, extraPeerCount: extraPeerCount() },
      incoming: {
        depth: incoming.length,
        capacity: MaxQueuedPackets,
        oldestAgeMs: oldest ? Math.max(0, now - oldest.queuedAt) : null,
        dequeuedTotal: stats.dequeuedPackets,
        droppedTotal: stats.droppedPackets,
      },
      send: {
        attempts: stats.sendAttempts,
        pending: 0,
        sentPackets: stats.sentPackets.slice(),
      },
      receivedPackets: stats.receivedPackets.slice(),
      connects: stats.connects.slice(),
      selectedPeer: null,
    };
  }

  globalThis.ZigfallTransport = Object.freeze({
    MaxPacketSize,
    MaxQueuedPackets,
    Status,
    ErrorCode,
    selfId,
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
    healthErrorCode: () => ErrorCode.none,
    healthErrorName: () => "none",
    healthErrorMessage: () => "",
    peerCount: () => peers.size,
    peerIds: () => Array.from(peers),
    selectedPeerId: () => selectedPeerId,
    hadPeer: () => peers.size > 0 || selectedPeerId !== null,
    extraPeerCount,
    queuedPacketCount: () => incoming.length,
    roomId: () => roomId,
    debugSnapshot,
  });
})();
