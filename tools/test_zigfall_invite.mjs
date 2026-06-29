// SPDX-License-Identifier: GPL-3.0-or-later

import assert from "node:assert/strict";
import { CopyStatus, ErrorCode, createZigfallInvite } from "../web/zigfall_invite.mjs";

function deterministicCrypto() {
  return {
    getRandomValues(view) {
      for (let i = 0; i < view.length; i += 1) view[i] = (i * 17 + 3) & 0xff;
      return view;
    },
  };
}

function fallbackDocument({ success }) {
  const appended = [];
  return {
    body: {
      appendChild(node) {
        appended.push(node);
      },
      removeChild(node) {
        assert.equal(appended.pop(), node);
      },
    },
    createElement(tagName) {
      assert.equal(tagName, "textarea");
      return {
        style: {},
        value: "",
        selected: false,
        setAttribute(name, value) {
          this[name] = value;
        },
        focus() {},
        select() {
          this.selected = true;
        },
        setSelectionRange(start, end) {
          this.selection = [start, end];
        },
      };
    },
    execCommand(command) {
      assert.equal(command, "copy");
      assert.equal(appended.length, 1);
      assert.equal(appended[0].selected, true);
      return success;
    },
  };
}

async function flushMicrotasks() {
  await Promise.resolve();
  await Promise.resolve();
}

{
  const invite = createZigfallInvite({
    locationImpl: { href: "https://play.example.test/zigfall/?join=room-._~A0&foo=bar" },
  });

  assert.equal(invite.initialJoinRoom(), "room-._~A0");
  assert.deepEqual(invite.readInitialJoinRoom(), { roomId: "room-._~A0", errorCode: ErrorCode.none });
}

{
  const missing = createZigfallInvite({ locationImpl: { href: "https://play.example.test/zigfall/?foo=bar" } });
  assert.equal(missing.initialJoinRoom(), null);
  assert.deepEqual(missing.readInitialJoinRoom(), { roomId: null, errorCode: ErrorCode.none });

  const invalid = createZigfallInvite({ locationImpl: { href: "https://play.example.test/zigfall/?join=bad%20room" } });
  const invalidResult = invalid.readInitialJoinRoom();
  assert.equal(invalidResult.roomId, null);
  assert.equal(invalidResult.errorCode, ErrorCode.badRoom);

  const empty = createZigfallInvite({ locationImpl: { href: "https://play.example.test/zigfall/?join=" } });
  assert.equal(empty.readInitialJoinRoom().errorCode, ErrorCode.badRoom);

  const tooLongRoom = "a".repeat(129);
  const tooLong = createZigfallInvite({ locationImpl: { href: `https://play.example.test/zigfall/?join=${tooLongRoom}` } });
  assert.equal(tooLong.readInitialJoinRoom().errorCode, ErrorCode.badRoom);
}

{
  const invite = createZigfallInvite({ cryptoImpl: deterministicCrypto() });
  const roomId = invite.createHostRoom();
  assert.equal(roomId.length, 24, "18 random bytes should encode to 24 base64url characters");
  assert.match(roomId, /^[A-Za-z0-9_-]+$/);
  assert.equal(invite.validateRoomId(roomId), roomId);
}

{
  const invite = createZigfallInvite({
    locationImpl: { href: "https://example.test/play/zigfall.html?foo=1&join=old#frag" },
  });
  const href = invite.joinUrl("room_123-ABC");
  const url = new URL(href);
  assert.equal(url.origin, "https://example.test");
  assert.equal(url.pathname, "/play/zigfall.html");
  assert.equal(url.searchParams.get("foo"), null);
  assert.equal(url.searchParams.get("join"), "room_123-ABC");
  assert.equal(url.hash, "");

  assert.throws(() => invite.joinUrl("bad room"), { code: ErrorCode.badRoom });
}

{
  const writes = [];
  const invite = createZigfallInvite({
    navigatorImpl: { clipboard: { writeText: async (text) => writes.push(text) } },
    documentImpl: null,
  });

  assert.equal(await invite.copyText("copy me"), CopyStatus.copied);
  assert.deepEqual(writes, ["copy me"]);
  assert.equal(invite.copyStatus(), CopyStatus.copied);
  assert.equal(invite.copyErrorMessage(), "");
}

{
  const invite = createZigfallInvite({
    navigatorImpl: { clipboard: { writeText: async () => { throw new Error("denied"); } } },
    documentImpl: fallbackDocument({ success: true }),
  });

  assert.equal(await invite.copyText("fallback me"), CopyStatus.fallback);
  assert.equal(invite.copyStatus(), CopyStatus.fallback);
  assert.equal(invite.copyErrorMessage(), "");
}

{
  const invite = createZigfallInvite({ navigatorImpl: {}, documentImpl: null });
  assert.equal(await invite.copyText("nowhere"), CopyStatus.failed);
  assert.equal(invite.copyStatus(), CopyStatus.failed);
  assert.match(invite.copyErrorMessage(), /clipboard API is unavailable/);
}

{
  let resolveWrite;
  const writes = [];
  const invite = createZigfallInvite({
    navigatorImpl: {
      clipboard: {
        writeText(text) {
          writes.push(text);
          return new Promise((resolve) => {
            resolveWrite = resolve;
          });
        },
      },
    },
    documentImpl: null,
  });

  assert.equal(invite.requestCopyText("pending copy"), ErrorCode.none);
  assert.equal(invite.copyStatus(), CopyStatus.pending);
  await flushMicrotasks();
  assert.deepEqual(writes, ["pending copy"]);
  resolveWrite();
  await flushMicrotasks();
  assert.equal(invite.copyStatus(), CopyStatus.copied);
}

{
  const writes = [];
  const invite = createZigfallInvite({
    locationImpl: { href: "https://example.test/game/" },
    navigatorImpl: { clipboard: { writeText: async (text) => writes.push(text) } },
    documentImpl: null,
  });

  assert.equal(invite.requestCopyJoinUrl("room-ok"), ErrorCode.none);
  await flushMicrotasks();
  assert.equal(new URL(writes[0]).searchParams.get("join"), "room-ok");
  assert.equal(invite.requestCopyJoinUrl("../bad"), ErrorCode.badRoom);
}

console.log("ok: Zigfall invite helper parses, generates, links, and copies bounded URL-safe room IDs");
