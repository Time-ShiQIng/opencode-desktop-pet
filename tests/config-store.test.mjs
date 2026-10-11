import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, readFile, mkdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
    syncSources,
    listLibrary,
    importLibraryPet,
    activateLibraryPet,
    removeLibraryPet,
    validPetId,
} from "../config-store.mjs";

async function setup() {
    const root = await mkdtemp(path.join(os.tmpdir(), "pet-cfg-"));
    const dataDir = path.join(root, "data");
    const extDir = path.join(root, "ext");
    await mkdir(dataDir, { recursive: true });
    await mkdir(extDir, { recursive: true });
    await writeFile(path.join(extDir, "pet.json"), JSON.stringify({ name: "ext", sprite: "a.png" }));
    await writeFile(path.join(extDir, "a.png"), "x");
    return { root, dataDir, extDir };
}

test("validPetId accepts uuid only", () => {
    assert.equal(validPetId("00000000-0000-4000-8000-000000000001"), true);
    assert.equal(validPetId("../evil"), false);
});

test("first sync migrates legacy extension pet.json", async () => {
    const { root, dataDir, extDir } = await setup();
    try {
        await syncSources(dataDir, extDir);
        const cfg = JSON.parse(await readFile(path.join(dataDir, "pet.json"), "utf8"));
        assert.equal(cfg.name, "ext");
        assert.equal(cfg.sprite, "a.png");
    } finally { await rm(root, { recursive: true, force: true }); }
});

test("import, list, activate and delete library pets", async () => {
    const { root, dataDir, extDir } = await setup();
    try {
        await syncSources(dataDir, extDir);
        const id1 = await importLibraryPet(dataDir, extDir, { name: "one", sprite: "x" }, Buffer.from("png"), ".png");
        const id2 = await importLibraryPet(dataDir, extDir, { name: "two", sprite: "x" }, Buffer.from("gif"), ".gif");
        const list = await listLibrary(dataDir);
        assert.deepEqual(list.map((p) => p.name).sort(), ["one", "two"]);

        await activateLibraryPet(dataDir, extDir, id1);
        const active = JSON.parse(await readFile(path.join(dataDir, "pet.json"), "utf8"));
        assert.equal(active.name, "one");
        assert.equal(active.sprite, "pets/" + id1 + "/spritesheet.png");

        await removeLibraryPet(dataDir, extDir, id2);
        assert.equal((await listLibrary(dataDir)).length, 1);
    } finally { await rm(root, { recursive: true, force: true }); }
});

test("cannot delete the last remaining active pet", async () => {
    const { root, dataDir, extDir } = await setup();
    try {
        await syncSources(dataDir, extDir);
        const id = await importLibraryPet(dataDir, extDir, { name: "only", sprite: "x" }, Buffer.from("png"), ".png");
        await assert.rejects(removeLibraryPet(dataDir, extDir, id), /请先导入/);
    } finally { await rm(root, { recursive: true, force: true }); }
});

test("rejects bad image extension", async () => {
    const { root, dataDir, extDir } = await setup();
    try {
        await assert.rejects(importLibraryPet(dataDir, extDir, {}, Buffer.from("x"), ".exe"), /贴图仅支持/);
    } finally { await rm(root, { recursive: true, force: true }); }
});
