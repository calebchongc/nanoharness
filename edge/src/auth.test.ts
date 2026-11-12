import { SignJWT } from "jose";
import { describe, expect, it } from "vitest";
import { authenticate, issueRefreshCredential, localAuthRoute, verifyRefreshCredential, verifyToken } from "./auth";
import type { Env } from "./env";

const env = { HARNESS_AUTH_SIGNING_KEY: "k".repeat(48) } as Env;
const other = { HARNESS_AUTH_SIGNING_KEY: "z".repeat(48) } as Env;
const CG = "cg_rt_secret-refresh-token";

// Synthetic session; generated afresh by the local runner in real use.
describe("explicit local sessions", () => {
  const local = {
    AUTH_MODE: "local",
    HARNESS_LOCAL_SESSION_TOKEN: "synthetic-local-session-01234567890123456789",
    HARNESS_LOCAL_SESSION_USER: "ada-synthetic"
  } as Env;
  const request = (host: string, token = local.HARNESS_LOCAL_SESSION_TOKEN) =>
    new Request(`http://${host}/auth/local-session`, { headers: { authorization: `Bearer ${token}` } });

  it("accepts only the configured session on a literal loopback URL", async () => {
    expect(await authenticate(local, request("127.0.0.1:40123"))).toEqual({
      userId: "ada-synthetic", orgId: "user-ada-synthetic"
    });
    expect(await authenticate(local, request("127.0.0.1:40123", "arbitrary@org"))).toBeUndefined();
    expect(await authenticate(local, new Request("http://127.0.0.1:40123/"))).toBeUndefined();
  });

  it("local-only routes verify sessions and cannot run production OAuth", async () => {
    const url = "http://127.0.0.1:40123";
    const ok = await localAuthRoute(local, request("127.0.0.1:40123"));
    expect(ok?.status).toBe(200);
    expect(await ok?.json()).toEqual({ mode: "local", userId: "ada-synthetic", orgId: "user-ada-synthetic" });
    expect((await localAuthRoute(local, request("127.0.0.1:40123", "stale-session")))?.status).toBe(401);
    expect((await localAuthRoute(local, request("edge.codegraff.com")))?.status).toBe(403);
    expect(await localAuthRoute({ ...local, AUTH_MODE: "codegraff" }, request("127.0.0.1:40123"))).toBeUndefined();
    for (const path of ["exchange", "refresh", "sandbox", "account/delete"]) {
      const r = new Request(`${url}/auth/${path}`, { method: "POST", headers: { authorization: `Bearer ${local.HARNESS_LOCAL_SESSION_TOKEN}` } });
      expect((await localAuthRoute(local, r))?.status).toBe(404);
    }
  });

  it("fails closed without a session and never authorizes remote or production URLs", async () => {
    expect(await authenticate({ ...local, HARNESS_LOCAL_SESSION_TOKEN: undefined }, request("127.0.0.1"))).toBeUndefined();
    for (const host of ["edge.codegraff.com", "localhost", "127.0.0.1.example.invalid", "192.0.2.1"]) {
      expect(await authenticate(local, request(host))).toBeUndefined();
    }
    expect(await verifyToken({ ...local, AUTH_MODE: "codegraff" }, local.HARNESS_LOCAL_SESSION_TOKEN!)).toBeUndefined();
  });
});

describe("refresh credential", () => {
  it("is encrypted and keeps the prefix shipped engines accept", async () => {
    const credential = await issueRefreshCredential(env, "42", CG);
    expect(credential.startsWith("harness_rt_")).toBe(true);
    const body = credential.slice("harness_rt_".length);
    expect(body.split(".")).toHaveLength(5);
    const decoded = body
      .split(".")
      .map((part) => {
        try {
          return atob(part.replace(/-/g, "+").replace(/_/g, "/"));
        } catch {
          return "";
        }
      })
      .join("");
    expect(decoded.includes("cg_rt_")).toBe(false);
    expect(credential.includes("cg_rt_")).toBe(false);
  });

  it("round-trips", async () => {
    const credential = await issueRefreshCredential(env, "42", CG);
    expect(await verifyRefreshCredential(env, credential)).toEqual({
      userId: "42",
      codegraffRefreshToken: CG
    });
  });

  it("rejects another key and tampering", async () => {
    const credential = await issueRefreshCredential(env, "42", CG);
    expect(await verifyRefreshCredential(other, credential)).toBeUndefined();
    const flipped = credential.slice(0, -2) + (credential.endsWith("A") ? "B" : "A") + credential.slice(-1);
    expect(await verifyRefreshCredential(env, flipped)).toBeUndefined();
    expect(await verifyRefreshCredential(env, "harness_rt_a.b.c.d")).toBeUndefined();
    expect(await verifyRefreshCredential(env, "nope")).toBeUndefined();
  });

  it("still accepts a legacy signed credential for its one refresh", async () => {
    const jwt = await new SignJWT({ codegraff_refresh_token: CG })
      .setProtectedHeader({ alg: "HS256" })
      .setIssuer("https://edge.codegraff.com")
      .setAudience("harness-edge-refresh")
      .setSubject("42")
      .setIssuedAt()
      .setExpirationTime("30d")
      .sign(new TextEncoder().encode(env.HARNESS_AUTH_SIGNING_KEY));
    expect(await verifyRefreshCredential(env, `harness_rt_${jwt}`)).toEqual({
      userId: "42",
      codegraffRefreshToken: CG
    });
  });
});
