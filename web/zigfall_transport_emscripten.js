// SPDX-License-Identifier: GPL-3.0-or-later

mergeInto(LibraryManager.library, {
  $ZigfallTransportShim: {
    Status: {
      missingJs: 1,
    },
    ErrorCode: {
      none: 0,
      missingJs: 1,
      bufferTooSmall: 10,
    },
    decoder: null,
    transport: function() {
      var transport = globalThis.ZigfallTransport;
      return transport && typeof transport.statusCode === "function" ? transport : null;
    },
    decodeUtf8: function(ptr, len) {
      if (!this.decoder) this.decoder = new TextDecoder("utf-8", { fatal: false });
      return this.decoder.decode(HEAPU8.subarray(ptr, ptr + len));
    },
  },

  zigfall_transport_status__deps: ["$ZigfallTransportShim"],
  zigfall_transport_status: function() {
    var transport = ZigfallTransportShim.transport();
    return transport ? transport.statusCode() : ZigfallTransportShim.Status.missingJs;
  },

  zigfall_transport_last_error__deps: ["$ZigfallTransportShim"],
  zigfall_transport_last_error: function() {
    var transport = ZigfallTransportShim.transport();
    return transport ? transport.errorCode() : ZigfallTransportShim.ErrorCode.missingJs;
  },

  zigfall_transport_connect__deps: ["$ZigfallTransportShim"],
  zigfall_transport_connect: function(roomPtr, roomLen) {
    var transport = ZigfallTransportShim.transport();
    if (!transport) return ZigfallTransportShim.ErrorCode.missingJs;
    return transport.connect(ZigfallTransportShim.decodeUtf8(roomPtr, roomLen));
  },

  zigfall_transport_disconnect__deps: ["$ZigfallTransportShim"],
  zigfall_transport_disconnect: function() {
    var transport = ZigfallTransportShim.transport();
    if (transport) transport.disconnect();
  },

  zigfall_transport_send__deps: ["$ZigfallTransportShim"],
  zigfall_transport_send: function(packetPtr, packetLen) {
    var transport = ZigfallTransportShim.transport();
    if (!transport) return ZigfallTransportShim.ErrorCode.missingJs;
    var packet = new Uint8Array(HEAPU8.subarray(packetPtr, packetPtr + packetLen));
    return transport.send(packet);
  },

  zigfall_transport_poll__deps: ["$ZigfallTransportShim"],
  zigfall_transport_poll: function(outPtr, outCap) {
    var transport = ZigfallTransportShim.transport();
    if (!transport) return -ZigfallTransportShim.ErrorCode.missingJs;
    return transport.pollInto(HEAPU8, outPtr, outCap);
  },

  zigfall_transport_peer_count__deps: ["$ZigfallTransportShim"],
  zigfall_transport_peer_count: function() {
    var transport = ZigfallTransportShim.transport();
    return transport ? transport.peerCount() : 0;
  },

  zigfall_transport_queued_packet_count__deps: ["$ZigfallTransportShim"],
  zigfall_transport_queued_packet_count: function() {
    var transport = ZigfallTransportShim.transport();
    return transport ? transport.queuedPacketCount() : 0;
  },
});
