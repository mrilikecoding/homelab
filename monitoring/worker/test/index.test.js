import { describe, it, expect, vi, afterEach } from "vitest";
import worker, { evaluate } from "../src/index.js";

function jsonResponse(body, { ok = true, status = 200 } = {}) {
  return { ok, status, json: async () => body };
}

function freshBody(overrides = {}) {
  return {
    generated: new Date().toISOString(),
    ok: true,
    checks: { colima: true, dns: true, serve: true },
    ...overrides,
  };
}

function fakeState(initial = {}) {
  const map = new Map(Object.entries(initial));
  return {
    get: vi.fn(async (key) => map.get(key)),
    put: vi.fn(async (key, value) => {
      map.set(key, value);
    }),
  };
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("evaluate", () => {
  it("returns not-ok for a non-200 response", async () => {
    const res = { ok: false, status: 503, json: async () => ({}) };

    const result = await evaluate(res, Date.now());

    expect(result).toEqual({ ok: false, why: "status.json 503" });
  });

  it("returns not-ok with stale for a 16 minute old timestamp", async () => {
    const now = Date.now();
    const generated = new Date(now - 16 * 60 * 1000).toISOString();
    const res = jsonResponse({ generated, ok: true, checks: {} });

    const result = await evaluate(res, now);

    expect(result).toEqual({ ok: false, why: "stale 16 min" });
  });

  it("names every red check for a failing status body", async () => {
    const res = jsonResponse(
      freshBody({ ok: false, checks: { colima: true, dns: false, serve: false } }),
    );

    const result = await evaluate(res, Date.now());

    expect(result).toEqual({ ok: false, why: "red: dns, serve" });
  });

  it("returns ok for a fresh green body", async () => {
    const res = jsonResponse(freshBody());

    const result = await evaluate(res, Date.now());

    expect(result).toEqual({ ok: true, why: "ok" });
  });

  it.each([
    ["missing", { ok: true, checks: {} }],
    ["unparseable", { generated: "not-a-date", ok: true, checks: {} }],
  ])("treats a %s timestamp as not-ok, naming the missing timestamp", async (_label, body) => {
    const res = jsonResponse(body);

    const result = await evaluate(res, Date.now());

    expect(result.ok).toBe(false);
    expect(result.why).toBe("no timestamp in status.json");
  });

  it("returns not-ok when a 200 response body is not valid JSON", async () => {
    const res = {
      ok: true,
      status: 200,
      json: async () => {
        throw new SyntaxError("Unexpected token < in JSON");
      },
    };

    const result = await evaluate(res, Date.now());

    expect(result).toEqual({ ok: false, why: "status.json body not valid JSON" });
  });
});

describe("scheduled", () => {
  const STATUS_URL = "https://status.example/status.json";
  const NTFY_TOPIC = "test-topic";

  function ntfyCalls(fetchMock) {
    return fetchMock.mock.calls.filter(([url]) => url === `https://ntfy.sh/${NTFY_TOPIC}`);
  }

  it("posts exactly one ntfy call when state goes from ok to down", async () => {
    const fetchMock = vi.fn(async (url) => {
      if (url === STATUS_URL) {
        return jsonResponse(freshBody({ ok: false, checks: { dns: false } }));
      }
      return { ok: true, status: 200, json: async () => ({}) };
    });
    vi.stubGlobal("fetch", fetchMock);
    const state = fakeState({ last: "ok" });
    const env = { STATUS_URL, NTFY_TOPIC, STATE: state };

    await worker.scheduled({}, env);

    const calls = ntfyCalls(fetchMock);
    expect(calls).toHaveLength(1);
    const [url, options] = calls[0];
    expect(url).toBe(`https://ntfy.sh/${NTFY_TOPIC}`);
    expect(options.method).toBe("POST");
    expect(options.headers.Title).toBe("homelab DOWN");
    expect(options.headers.Priority).toBe("high");
    expect(options.headers.Tags).toBe("rotating_light");
    expect(options.body).toMatch(/^red: dns \(/);
    expect(state.put).toHaveBeenCalledWith("last", "down");
  });

  it("does not persist state when the ntfy POST fails (ok to down)", async () => {
    const fetchMock = vi.fn(async (url) => {
      if (url === STATUS_URL) {
        return jsonResponse(freshBody({ ok: false, checks: { dns: false } }));
      }
      return { ok: false, status: 500, json: async () => ({}) };
    });
    vi.stubGlobal("fetch", fetchMock);
    const state = fakeState({ last: "ok" });
    const env = { STATUS_URL, NTFY_TOPIC, STATE: state };

    await worker.scheduled({}, env);

    expect(ntfyCalls(fetchMock)).toHaveLength(1);
    expect(state.put).not.toHaveBeenCalled();
  });

  it("does not persist state when the ntfy fetch throws (ok to down)", async () => {
    const fetchMock = vi.fn(async (url) => {
      if (url === STATUS_URL) {
        return jsonResponse(freshBody({ ok: false, checks: { dns: false } }));
      }
      throw new Error("network down");
    });
    vi.stubGlobal("fetch", fetchMock);
    const state = fakeState({ last: "ok" });
    const env = { STATUS_URL, NTFY_TOPIC, STATE: state };

    await worker.scheduled({}, env);

    expect(ntfyCalls(fetchMock)).toHaveLength(1);
    expect(state.put).not.toHaveBeenCalled();
  });

  it("posts nothing when state stays down", async () => {
    const fetchMock = vi.fn(async (url) => {
      if (url === STATUS_URL) {
        return jsonResponse(freshBody({ ok: false, checks: { dns: false } }));
      }
      return { ok: true, status: 200, json: async () => ({}) };
    });
    vi.stubGlobal("fetch", fetchMock);
    const state = fakeState({ last: "down" });
    const env = { STATUS_URL, NTFY_TOPIC, STATE: state };

    await worker.scheduled({}, env);

    expect(ntfyCalls(fetchMock)).toHaveLength(0);
    expect(state.put).not.toHaveBeenCalled();
  });

  it("posts the recovery when state goes from down to ok", async () => {
    const fetchMock = vi.fn(async (url) => {
      if (url === STATUS_URL) {
        return jsonResponse(freshBody());
      }
      return { ok: true, status: 200, json: async () => ({}) };
    });
    vi.stubGlobal("fetch", fetchMock);
    const state = fakeState({ last: "down" });
    const env = { STATUS_URL, NTFY_TOPIC, STATE: state };

    await worker.scheduled({}, env);

    const calls = ntfyCalls(fetchMock);
    expect(calls).toHaveLength(1);
    const [url, options] = calls[0];
    expect(url).toBe(`https://ntfy.sh/${NTFY_TOPIC}`);
    expect(options.method).toBe("POST");
    expect(options.headers.Title).toBe("homelab recovered");
    expect(options.headers.Priority).toBe("default");
    expect(options.headers.Tags).toBe("white_check_mark");
    expect(options.body).toMatch(/^ok \(/);
    expect(state.put).toHaveBeenCalledWith("last", "ok");
  });
});
