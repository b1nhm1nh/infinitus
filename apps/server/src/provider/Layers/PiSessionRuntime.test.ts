import { describe, expect, it } from "@effect/vitest";
import * as NodeOS from "node:os";

import { piRpcArgs, piRpcEnvironment } from "./PiSessionRuntime.ts";

describe("piRpcArgs", () => {
  it("always speaks the RPC protocol, and omits a model when none was resolved", () => {
    expect(piRpcArgs({})).toEqual(["--mode", "rpc"]);
  });

  it("passes a resolved model and session id through", () => {
    expect(piRpcArgs({ model: "zai/glm-5.3", sessionId: "t3-abc" })).toEqual([
      "--mode",
      "rpc",
      "--model",
      "zai/glm-5.3",
      "--session-id",
      "t3-abc",
    ]);
  });
});

describe("piRpcEnvironment", () => {
  it("strips an ambient PI_CODING_AGENT_DIR", () => {
    // Oh My Pi is a fork of Pi that kept `APP_NAME = "pi"`, so it derives and
    // sets this very variable. Inheriting it would point both agents at one
    // directory and have each read the other's sessions.
    const env = piRpcEnvironment({ PATH: "/usr/bin", PI_CODING_AGENT_DIR: "/omp/home" }, undefined);
    expect(env.PI_CODING_AGENT_DIR).toBeUndefined();
    expect(env.PATH).toBe("/usr/bin");
  });

  it("an explicit home wins over an ambient one", () => {
    const env = piRpcEnvironment({ PI_CODING_AGENT_DIR: "/omp/home" }, "/pi/home");
    expect(env.PI_CODING_AGENT_DIR).toBe("/pi/home");
  });

  it("expands a leading ~, which spawn would otherwise pass verbatim", () => {
    const env = piRpcEnvironment({}, "~/.pi/agent");
    expect(env.PI_CODING_AGENT_DIR).toBe(`${NodeOS.homedir()}/.pi/agent`);
  });
});
