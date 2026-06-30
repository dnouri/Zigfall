// SPDX-License-Identifier: GPL-3.0-or-later

import assert from "node:assert/strict";
import {
  AnonymousPlayerId,
  DefaultNickname,
  DefaultRating,
  ErrorCode,
  MaxNicknameLength,
  MaxSerializedCardBytes,
  ProfileResult,
  Status,
  StorageKey,
  createZigfallProfile,
  sanitizeNickname,
  validatePlayerId,
} from "../web/zigfall_profile.mjs";

const ExpectedDeterministicId = "p_031425364758697a8b9cadbecfe0f102";

function deterministicCrypto(offset = 3) {
  return {
    getRandomValues(view) {
      for (let i = 0; i < view.length; i += 1) view[i] = (i * 17 + offset) & 0xff;
      return view;
    },
  };
}

function memoryStorage(initial = {}) {
  const items = new Map(Object.entries(initial).map(([key, value]) => [key, String(value)]));
  return {
    getItem(key) {
      return items.has(key) ? items.get(key) : null;
    },
    setItem(key, value) {
      items.set(key, String(value));
    },
    removeItem(key) {
      items.delete(key);
    },
    clear() {
      items.clear();
    },
  };
}

function throwingStorage() {
  return {
    getItem() {
      throw new Error("storage blocked");
    },
    setItem() {
      throw new Error("storage blocked");
    },
  };
}

function storageThatFailsAfterInitialSave() {
  const storage = memoryStorage();
  let writesLeft = 1;
  return {
    getItem: storage.getItem,
    setItem(key, value) {
      if (writesLeft <= 0) throw new Error("quota exceeded after start");
      writesLeft -= 1;
      storage.setItem(key, value);
    },
    snapshot: () => storage.getItem(StorageKey),
  };
}

function lyingStorage() {
  return {
    getItem() {
      return null;
    },
    setItem() {
      // Deliberately ignore writes.
    },
  };
}

function freshMemoryOnlyProfile() {
  return createZigfallProfile({ storageImpl: null, cryptoImpl: deterministicCrypto() });
}

{
  const storage = memoryStorage();
  const profile = createZigfallProfile({ storageImpl: storage, cryptoImpl: deterministicCrypto() });
  const card = profile.card();

  assert.equal(profile.statusCode(), Status.ready);
  assert.equal(profile.lastErrorMessage(), "");
  assert.equal(card.playerId, ExpectedDeterministicId);
  assert.equal(card.nickname, DefaultNickname);
  assert.equal(card.rating, DefaultRating);
  assert.equal(card.wins, 0);
  assert.equal(card.losses, 0);
  assert.equal(card.draws, 0);
  assert.equal(validatePlayerId(card.playerId), card.playerId);
  assert.equal(storage.getItem(StorageKey), profile.serializeCard());
  assert.ok(profile.serializeCard().length <= MaxSerializedCardBytes);
}

{
  const storage = memoryStorage();
  const profile = createZigfallProfile({ storageImpl: storage, cryptoImpl: deterministicCrypto() });
  profile.setNickname("  Ada\t  Lovelace\u202e  ");
  const afterWin = profile.applyVerifiedResult(ProfileResult.win, DefaultRating);

  assert.equal(afterWin.nickname, "Ada Lovelace");
  assert.equal(afterWin.rating, 1016);
  assert.equal(afterWin.wins, 1);
  assert.equal(afterWin.losses, 0);
  assert.equal(afterWin.draws, 0);

  const reloaded = createZigfallProfile({ storageImpl: storage, cryptoImpl: deterministicCrypto(99) });
  assert.deepEqual(reloaded.card(), afterWin);
  assert.equal(reloaded.statusCode(), Status.ready);
}

{
  const storage = memoryStorage({ [StorageKey]: "{ this is not json" });
  const profile = createZigfallProfile({ storageImpl: storage, cryptoImpl: deterministicCrypto() });

  assert.equal(profile.statusCode(), Status.ready);
  assert.match(profile.lastErrorMessage(), /stored profile was reset/i);
  assert.equal(profile.card().playerId, ExpectedDeterministicId);
  assert.doesNotThrow(() => JSON.parse(storage.getItem(StorageKey)));
}

{
  const profile = createZigfallProfile({ storageImpl: throwingStorage(), cryptoImpl: deterministicCrypto() });

  assert.equal(profile.statusCode(), Status.memoryOnly);
  assert.match(profile.lastErrorMessage(), /localStorage|storage/i);
  assert.equal(profile.card().playerId, ExpectedDeterministicId);
  assert.equal(profile.card().rating, DefaultRating);
}

{
  const storage = storageThatFailsAfterInitialSave();
  const profile = createZigfallProfile({ storageImpl: storage, cryptoImpl: deterministicCrypto() });
  const persistedBeforeMutation = storage.snapshot();

  assert.equal(profile.statusCode(), Status.ready);
  const updated = profile.applyVerifiedResult(ProfileResult.win, DefaultRating);
  assert.equal(updated.rating, 1016);
  assert.equal(updated.wins, 1);
  assert.equal(profile.statusCode(), Status.memoryOnly, "mutation-time save failure must be visible to Zig/UI");
  assert.match(profile.lastErrorMessage(), /save failed|quota exceeded/i);
  assert.equal(storage.snapshot(), persistedBeforeMutation, "failed mutation must not be reported as persisted");
}

{
  const profile = createZigfallProfile({ storageImpl: lyingStorage(), cryptoImpl: deterministicCrypto() });

  assert.equal(profile.statusCode(), Status.memoryOnly, "storage write verification failure must not claim durability");
  assert.match(profile.lastErrorMessage(), /save verification failed/i);
  const card = profile.setNickname("Verified In Memory");
  assert.equal(card.nickname, "Verified In Memory");
  assert.equal(profile.statusCode(), Status.memoryOnly);
}

{
  const storage = memoryStorage();
  const profile = createZigfallProfile({ storageImpl: storage, cryptoImpl: null });

  assert.equal(profile.statusCode(), Status.cryptoUnavailable);
  assert.match(profile.lastErrorMessage(), /crypto/i);
  assert.equal(profile.card().playerId, AnonymousPlayerId);
  assert.equal(storage.getItem(StorageKey), null, "anonymous crypto-fallback profiles must not become persistent IDs");
}

{
  assert.equal(sanitizeNickname(" \tAda\nLovelace\u202e😈! "), "Ada Lovelace");
  assert.equal(sanitizeNickname("\u202e\u0000\u001f"), DefaultNickname);
  assert.equal(sanitizeNickname("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), "ABCDEFGHIJKLMNOPQRSTUVWXYZ".slice(0, MaxNicknameLength));

  const profile = freshMemoryOnlyProfile();
  const card = profile.setNickname(" Name!@#._-   ok ");
  assert.equal(card.nickname, "Name._- ok");
}

{
  const winner = freshMemoryOnlyProfile();
  assert.equal(winner.applyVerifiedResult("win", DefaultRating).rating, 1016);
  assert.equal(winner.card().wins, 1);
  assert.equal(winner.card().losses, 0);
  assert.equal(winner.card().draws, 0);

  const loser = freshMemoryOnlyProfile();
  assert.equal(loser.applyVerifiedResult("loss", DefaultRating).rating, 984);
  assert.equal(loser.card().wins, 0);
  assert.equal(loser.card().losses, 1);
  assert.equal(loser.card().draws, 0);

  const draw = freshMemoryOnlyProfile();
  assert.equal(draw.applyVerifiedResult("draw", 1200).rating, 1008);
  assert.equal(draw.card().wins, 0);
  assert.equal(draw.card().losses, 0);
  assert.equal(draw.card().draws, 1);
}

{
  const profile = freshMemoryOnlyProfile();
  const before = profile.card();
  const ignored = profile.recordMatchResult({ verified: false, outcome: "loss", opponentRating: 4000 });

  assert.equal(ignored.updated, false);
  assert.deepEqual(ignored.card, before);
  assert.deepEqual(profile.card(), before);

  assert.throws(() => profile.applyVerifiedResult("disconnect", DefaultRating), { code: ErrorCode.badResult });
  assert.deepEqual(profile.card(), before);
}

console.log("ok: Zigfall profile helper creates, persists, sanitizes, and updates browser-local profile cards");
