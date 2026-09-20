import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

import { gurus } from "./gurus.js";

const addedManagers = new Map([
  ["william-heard", {name: "William Heard", chineseName: "威廉·赫德", entityName: "Heard Capital LLC", cik: "0001796409", alternateCiks: []}],
  ["evan-mcgoff", {name: "Evan McGoff", chineseName: "埃文·麦戈夫", entityName: "DOCK STREET ASSET MANAGEMENT INC", cik: "0001172779", alternateCiks: []}],
  ["michael-cuggino", {name: "Michael Cuggino", chineseName: "迈克尔·库吉诺", entityName: "PACIFIC HEIGHTS ASSET MANAGEMENT LLC", cik: "0001323414", alternateCiks: []}],
  ["john-stamas", {name: "John Stamas", chineseName: "约翰·斯塔马斯", entityName: "Defender Capital, LLC.", cik: "0001766929", alternateCiks: []}],
  [
    "chris-hohn",
    {
      name: "Chris Hohn",
      chineseName: "克里斯·霍恩",
      entityName: "TCI Fund Management Ltd",
      cik: "0001647251",
      alternateCiks: ["0001362598"]
    }
  ],
  [
    "david-tepper",
    {
      name: "David Tepper",
      chineseName: "大卫·泰珀",
      entityName: "Appaloosa LP",
      cik: "0001656456",
      alternateCiks: ["0001006438"]
    }
  ],
  [
    "dan-loeb",
    {
      name: "Dan Loeb",
      chineseName: "丹·勒布",
      entityName: "Third Point LLC",
      cik: "0001040273",
      alternateCiks: []
    }
  ],
  [
    "seth-klarman",
    {
      name: "Seth Klarman",
      chineseName: "塞思·卡拉曼",
      entityName: "Baupost Group LLC/MA",
      cik: "0001061768",
      alternateCiks: []
    }
  ],
  [
    "nelson-peltz",
    {
      name: "Nelson Peltz",
      chineseName: "纳尔逊·佩尔茨",
      entityName: "Trian Fund Management, L.P.",
      cik: "0001345471",
      alternateCiks: []
    }
  ],
  [
    "andreas-halvorsen",
    {
      name: "Andreas Halvorsen",
      chineseName: "安德烈亚斯·哈尔沃森",
      entityName: "Viking Global Investors LP",
      cik: "0001103804",
      alternateCiks: []
    }
  ],
  [
    "david-einhorn",
    {
      name: "David Einhorn",
      chineseName: "大卫·艾因霍恩",
      entityName: "DME Capital Management, LP",
      cik: "0001489933",
      alternateCiks: ["0001079114"]
    }
  ],
  [
    "mohnish-pabrai",
    {
      name: "Mohnish Pabrai",
      chineseName: "莫尼什·帕伯莱",
      entityName: "Dalal Street, LLC",
      cik: "0001549575",
      alternateCiks: ["0001173334"]
    }
  ],
  [
    "pat-dorsey",
    {
      name: "Pat Dorsey",
      chineseName: "帕特·多尔西",
      entityName: "Dorsey Asset Management, LLC",
      cik: "0001671657",
      alternateCiks: []
    }
  ]
]);

test("guru catalog has the audited manager population", () => {
  const managers = gurus.filter((guru) => guru.type === "manager13f");
  const enabledManagers = managers.filter((guru) => !guru.disableSimulation);

  assert.equal(gurus.length, 42);
  assert.equal(managers.length, 33);
  assert.equal(enabledManagers.length, 31);
  assert.deepEqual(
    managers.filter((guru) => guru.disableSimulation).map((guru) => guru.id).sort(),
    ["john-stamas", "nick-sleep-qais-zakaria"]
  );
});

test("guru IDs and SEC reporting entities are globally unique", () => {
  const ids = gurus.map((guru) => guru.id);
  assert.equal(new Set(ids).size, ids.length);

  const cikClaims = gurus.flatMap((guru) =>
    [guru.cik, ...(guru.alternateCiks || [])]
      .filter(Boolean)
      .map((cik) => ({ cik, guruId: guru.id }))
  );
  for (const { cik, guruId } of cikClaims) {
    assert.match(cik, /^\d{10}$/, `${guruId} has a non-normalized CIK`);
  }
  assert.equal(
    new Set(cikClaims.map(({ cik }) => cik)).size,
    cikClaims.length,
    "one SEC CIK must not be claimed by multiple configured profiles"
  );
});

test("every profile has a real Chinese display name instead of an English placeholder", () => {
  for (const guru of gurus) {
    assert.ok(guru.chineseName?.trim(), `${guru.id} has a Chinese display name`);
    assert.match(
      guru.chineseName,
      /[\u3400-\u9fff]/,
      `${guru.id} Chinese display name still contains only Latin text`
    );
  }
});

test("the added managers have complete bilingual and strategy metadata", () => {
  for (const [id, expected] of addedManagers) {
    const guru = gurus.find((candidate) => candidate.id === id);
    assert.ok(guru, `${id} is configured`);
    assert.equal(guru.type, "manager13f", `${id} uses the 13F pipeline`);
    if (id === "john-stamas") {
      assert.equal(guru.disableSimulation, true, `${id} fails closed for simulation`);
      assert.match(guru.simulationNote, /price-coverage threshold/);
    } else {
      assert.equal(guru.disableSimulation, undefined, `${id} keeps simulation enabled`);
    }
    assert.equal(guru.name, expected.name);
    assert.equal(guru.chineseName, expected.chineseName);
    assert.match(guru.chineseName, /[\u3400-\u9fff]/, `${id} has a Chinese display name`);
    assert.equal(guru.entityName, expected.entityName);
    assert.equal(guru.cik, expected.cik);
    assert.deepEqual(guru.alternateCiks || [], expected.alternateCiks);
    assert.ok(guru.role?.trim(), `${id} has a role`);
    assert.ok(guru.thesisTag?.trim(), `${id} has a thesis tag`);
    assert.ok(Array.isArray(guru.notes), `${id} has disclosure notes`);
    assert.ok(guru.notes.length >= 2, `${id} has enough disclosure notes`);
    assert.ok(guru.notes.every((note) => typeof note === "string" && note.trim()), `${id} notes are complete`);
  }
});

test("audited manager predecessor CIKs are explicit and exact", () => {
  const expectedTransitions = {
    "chris-hohn": ["0001362598"],
    "david-tepper": ["0001006438"],
    "david-einhorn": ["0001079114"],
    "mohnish-pabrai": ["0001173334"]
  };

  for (const [id, alternateCiks] of Object.entries(expectedTransitions)) {
    assert.deepEqual(gurus.find((guru) => guru.id === id)?.alternateCiks, alternateCiks);
  }
});

test("every added manager strategy tag has a Chinese UI translation", () => {
  const mainSource = fs.readFileSync(new URL("../lib/main.dart", import.meta.url), "utf8");
  for (const id of addedManagers.keys()) {
    const thesisTag = gurus.find((guru) => guru.id === id)?.thesisTag;
    assert.ok(
      mainSource.includes(`'${thesisTag}':`),
      `${id} thesis tag is missing from the Chinese UI dictionary`
    );
  }
});
