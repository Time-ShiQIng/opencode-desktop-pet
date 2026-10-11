import { test } from "node:test";
import assert from "node:assert/strict";
import {
    createPetState, markWorking, markIdle, computeActivity, sanitizeActivity,
    setAnimation, resolveAnimAlias, clampPollMs, mergeConfig, say, visibleMessage, setLookAtOpenCode,
} from "../state.mjs";

test("working then idle flips activity", () => {
    const s = createPetState(0);
    assert.equal(s.activity, "idle");
    markWorking(s, 1000);
    assert.equal(s.activity, "working");
    const r = markIdle(s, 2000, { suppressMs: 7000 });
    assert.equal(r.wasWorking, true);
    assert.equal(s.activity, "idle");
    assert.ok(s.explicitIdleUntil > 2000);
});

test("computeActivity honors explicit-idle suppression", () => {
    const s = createPetState(0);
    markWorking(s, 0);
    markIdle(s, 100, { suppressMs: 7000 });
    const out = computeActivity({ state: s, entries: [], now: 500, fallbackActive: true });
    assert.equal(out.activity, "idle");
    assert.equal(out.source, "explicit-idle");
});

test("sanitizeActivity normalizes synonyms", () => {
    assert.equal(sanitizeActivity("busy"), "working");
    assert.equal(sanitizeActivity("stop"), "idle");
    assert.equal(sanitizeActivity("???"), null);
});

test("setAnimation validates against config", () => {
    const s = createPetState(0);
    const cfg = mergeConfig({ animations: { idle: { row: 0, frames: 1 }, walk: { row: 1, frames: 2 } } });
    assert.equal(setAnimation(s, "walk", cfg).ok, true);
    assert.equal(setAnimation(s, "nope", cfg).ok, false);
    assert.equal(setAnimation(s, "auto", cfg).animation, null);
});

test("resolveAnimAlias picks existing alias", () => {
    const cfg = mergeConfig({ animations: { failed: { row: 5, frames: 2 } } });
    assert.equal(resolveAnimAlias("error", cfg), "failed");
    assert.equal(resolveAnimAlias("sleep", cfg), null);
});

test("clampPollMs bounds", () => {
    assert.equal(clampPollMs(50, 250), 100);
    assert.equal(clampPollMs(99999, 250), 5000);
    assert.equal(clampPollMs("abc", 250), 250);
});

test("say/visibleMessage honor expiry", () => {
    const s = createPetState(0);
    say(s, "hi", 1, 1000);
    assert.equal(visibleMessage(s, 1500), "hi");
    assert.equal(visibleMessage(s, 3000), null);
});

test("setLookAtOpenCode toggles and accepts explicit state", () => {
    const s = createPetState(0);
    assert.equal(setLookAtOpenCode(s).lookAtOpenCode, true);
    assert.equal(setLookAtOpenCode(s, false).lookAtOpenCode, false);
    assert.equal(mergeConfig({}).behavior.lookAtOpenCode, false);
});
