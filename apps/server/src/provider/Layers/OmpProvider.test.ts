// @effect-diagnostics nodeBuiltinImport:off preferSchemaOverJson:off
import * as NodeServices from "@effect/platform-node/NodeServices";
import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Schema from "effect/Schema";
import { OmpSettings } from "@t3tools/contracts";

import {
  buildInitialOmpProviderSnapshot,
  checkOmpProviderStatus,
  parseOmpModelsCliOutput,
} from "./OmpProvider.ts";
import { writeFakeCli } from "../../testUtils/fakeCli.ts";

const decodeOmpSettings = Schema.decodeSync(OmpSettings);

const AUTHENTICATED_MODELS_JSON = JSON.stringify({
  models: [
    {
      provider: "google-antigravity",
      id: "gemini-3.1-pro",
      selector: "google-antigravity/gemini-3.1-pro",
      name: "Gemini 3.1 Pro",
      thinking: ["minimal", "low", "medium", "high"],
    },
    {
      provider: "google-antigravity",
      id: "claude-sonnet-4-6",
      selector: "google-antigravity/claude-sonnet-4-6",
      name: "Claude Sonnet 4.6",
      thinking: ["low", "medium", "high"],
    },
  ],
});

describe("parseOmpModelsCliOutput", () => {
  it("reads model slugs, names, and thinking descriptors from JSON", () => {
    const parsed = parseOmpModelsCliOutput(AUTHENTICATED_MODELS_JSON);
    expect(parsed.authenticated).toBe(true);
    expect(parsed.models.map((model) => model.slug)).toEqual([
      "google-antigravity/gemini-3.1-pro",
      "google-antigravity/claude-sonnet-4-6",
    ]);
    expect(parsed.models[0]?.name).toBe("Gemini 3.1 Pro");
    expect(parsed.models[0]?.capabilities?.optionDescriptors).toEqual([
      {
        id: "thinking",
        label: "Thinking",
        type: "select",
        options: [
          { id: "minimal", label: "minimal" },
          { id: "low", label: "low" },
          { id: "medium", label: "medium" },
          { id: "high", label: "high" },
        ],
      },
    ]);
  });

  it("treats unauthenticated prose as not authenticated", () => {
    const parsed = parseOmpModelsCliOutput("No models available. Set API keys to continue.\n");
    expect(parsed.authenticated).toBe(false);
    expect(parsed.models).toEqual([]);
  });

  it("treats empty stdout as not authenticated", () => {
    expect(parseOmpModelsCliOutput("").authenticated).toBe(false);
  });
});

describe("buildInitialOmpProviderSnapshot", () => {
  it.effect("returns a disabled snapshot when settings.enabled is false", () =>
    Effect.gen(function* () {
      const snapshot = yield* buildInitialOmpProviderSnapshot(
        decodeOmpSettings({ enabled: false }),
      );
      expect(snapshot.status).toBe("disabled");
      expect(snapshot.message).toContain("disabled");
    }),
  );

  it.effect("returns a disabled snapshot by default — Oh My Pi is opt-in", () =>
    Effect.gen(function* () {
      const snapshot = yield* buildInitialOmpProviderSnapshot(decodeOmpSettings({}));
      expect(snapshot.status).toBe("disabled");
    }),
  );
});

it.layer(NodeServices.layer)("checkOmpProviderStatus", (it) => {
  it.effect("returns a disabled snapshot without spawning when disabled", () =>
    Effect.gen(function* () {
      const snapshot = yield* checkOmpProviderStatus(decodeOmpSettings({ enabled: false }));
      expect(snapshot.status).toBe("disabled");
      expect(snapshot.installed).toBe(false);
    }),
  );

  const writeFakeOmpCli = (input: {
    readonly modelsOutput: string;
    readonly modelsExitCode?: number;
  }) =>
    Effect.gen(function* () {
      const fs = yield* FileSystem.FileSystem;
      const dir = yield* fs.makeTempDirectoryScoped({ prefix: "t3code-omp-probe-" });
      // Every invocation appends its argv, so a test can prove which
      // subcommands the probe ran — above all that it never ran `acp`.
      const argvLog = `${dir}/argv.log`;
      const path = writeFakeCli({
        directory: dir,
        name: "omp",
        source: [
          'import { appendFileSync as appendArgv } from "node:fs";',
          `appendArgv(${JSON.stringify(argvLog)}, process.argv.slice(2).join(" ") + "\\n");`,
          'if (process.argv[2] === "--version") {',
          '  process.stdout.write("omp/18.1.21\\n");',
          "  process.exit(0);",
          "}",
          'if (process.argv[2] === "models") {',
          // @effect-diagnostics-next-line preferSchemaOverJson:off
          `  process.stdout.write(${JSON.stringify(input.modelsOutput)});`,
          `  process.exit(${input.modelsExitCode ?? 0});`,
          "}",
          "process.exit(1);",
          "",
        ].join("\n"),
      });
      const readArgv = Effect.gen(function* () {
        const exists = yield* fs.exists(argvLog);
        if (!exists) return [] as ReadonlyArray<string>;
        const contents = yield* fs.readFileString(argvLog);
        return contents.split("\n").filter((line) => line.length > 0);
      });
      return { path, readArgv };
    });

  it.effect("reports ready with models --json slugs when signed in", () =>
    Effect.gen(function* () {
      const snapshot = yield* Effect.scoped(
        Effect.gen(function* () {
          const { path: ompPath } = yield* writeFakeOmpCli({
            modelsOutput: AUTHENTICATED_MODELS_JSON,
          });
          return yield* checkOmpProviderStatus(
            decodeOmpSettings({ enabled: true, binaryPath: ompPath }),
          );
        }),
      );

      expect(snapshot.status).toBe("ready");
      expect(snapshot.version).toBe("18.1.21");
      expect(snapshot.auth).toEqual({
        status: "authenticated",
        type: "cached_token",
        label: "omp providers",
      });
      expect(snapshot.models.map((model) => model.slug)).toEqual([
        "omp-default",
        "google-antigravity/gemini-3.1-pro",
        "google-antigravity/claude-sonnet-4-6",
      ]);
      expect(snapshot.models[0]?.name).toBe("Session default");
      expect(snapshot.supportsTextGeneration).toBeUndefined();
    }),
  );

  it.effect("reports unauthenticated from empty models --json as a warning", () =>
    Effect.gen(function* () {
      const snapshot = yield* Effect.scoped(
        Effect.gen(function* () {
          const { path: ompPath } = yield* writeFakeOmpCli({
            modelsOutput: "No models available. Set API keys to continue.\n",
          });
          return yield* checkOmpProviderStatus(
            decodeOmpSettings({ enabled: true, binaryPath: ompPath }),
          );
        }),
      );

      expect(snapshot.status).toBe("warning");
      expect(snapshot.auth.status).toBe("unauthenticated");
      expect(snapshot.message).toContain("Run `omp` once to sign in");
      expect(snapshot.models.map((model) => model.slug)).toEqual(["omp-default"]);
    }),
  );

  it.effect("probes with --version and models only, never starting ACP", () =>
    Effect.gen(function* () {
      const invocations = yield* Effect.scoped(
        Effect.gen(function* () {
          const { path: ompPath, readArgv } = yield* writeFakeOmpCli({
            modelsOutput: AUTHENTICATED_MODELS_JSON,
          });
          yield* checkOmpProviderStatus(decodeOmpSettings({ enabled: true, binaryPath: ompPath }));
          return yield* readArgv;
        }),
      );

      expect(invocations.length).toBeGreaterThan(0);
      // A health probe that spawned `omp acp` would hold an agent session
      // open for every refresh.
      expect(invocations.some((argv) => argv.split(" ").includes("acp"))).toBe(false);
      expect(invocations.every((argv) => argv === "--version" || argv.startsWith("models"))).toBe(
        true,
      );
    }),
  );
});
