import { describe, expect, it } from "@effect/vitest";
import { PI_DEFAULT_MODEL } from "@infinitus/contracts";

import { piStderrDetail, piTextGenerationArgs } from "./PiTextGeneration.ts";

describe("piTextGenerationArgs", () => {
  it("keeps one-shot runs out of Pi's session store", () => {
    // Without `--no-session` every generated commit message and thread title
    // lands in `sessions/<cwd>/` like a real conversation, and the project
    // scanner then offers our own internal prompts back as importable history.
    expect(piTextGenerationArgs(null)).toContain("--no-session");
    expect(piTextGenerationArgs("openai/gpt-5")).toContain("--no-session");
  });

  it("omits the sentinel default model, which Pi does not know", () => {
    expect(piTextGenerationArgs(PI_DEFAULT_MODEL)).toEqual(["-p", "--no-session"]);
    expect(piTextGenerationArgs("  ")).toEqual(["-p", "--no-session"]);
  });

  it("passes a real model through", () => {
    expect(piTextGenerationArgs("zai/glm-5.3")).toEqual([
      "-p",
      "--no-session",
      "--model",
      "zai/glm-5.3",
    ]);
  });
});

describe("piStderrDetail", () => {
  it("drops empty stderr and bounds a long one", () => {
    expect(piStderrDetail("   \n ")).toBeUndefined();
    expect(piStderrDetail(' Error: Model "x" not found ')).toBe('Error: Model "x" not found');
    const long = piStderrDetail("x".repeat(900));
    expect(long).toHaveLength(501);
    expect(long?.endsWith("…")).toBe(true);
  });
});
