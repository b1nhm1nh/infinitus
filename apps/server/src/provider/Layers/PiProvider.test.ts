// @effect-diagnostics nodeBuiltinImport:off - builds a fake `pi` CLI in a temp dir.
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import * as NodeServices from "@effect/platform-node/NodeServices";
import { expect, it } from "@effect/vitest";
import { PiSettings } from "@infinitus/contracts";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Schema from "effect/Schema";

import { writeFakeCli } from "../../testUtils/fakeCli.ts";
import { checkPiProviderStatus } from "./PiProvider.ts";

const decodePiSettings = Schema.decodeSync(PiSettings);

/**
 * A `pi` whose `--version` answers but whose `--list-models` behaves as the
 * test asks.
 *
 * There is no "hangs past the probe timeout" case: a timeout and a non-zero
 * exit both leave `modelsOutput` undefined and take the identical branch, and
 * the harness runs on TestClock so the probe's own timeout would never fire.
 */
const makeFakePi = Effect.fn("PiProvider.test.makeFakePi")(function* (
  listModels: "fail" | "empty",
) {
  const fileSystem = yield* FileSystem.FileSystem;
  const directory = yield* fileSystem.makeTempDirectoryScoped({ prefix: "pi-provider-test-" });
  const body =
    listModels === "fail"
      ? 'process.stderr.write("boom\\n"); process.exit(3);'
      : 'process.stdout.write("\\n"); process.exit(0);';
  return writeFakeCli({
    directory,
    name: "pi",
    source: [
      'if (process.argv.includes("--version")) {',
      '  process.stdout.write("0.85.1\\n");',
      "  process.exit(0);",
      "}",
      'if (process.argv.includes("--list-models")) {',
      `  ${body}`,
      "}",
    ].join("\n"),
  });
});

it.layer(NodeServices.layer)("checkPiProviderStatus", (it) => {
  it.effect("does not claim a signed-in user is signed out when the model probe fails", () =>
    Effect.gen(function* () {
      const binaryPath = yield* makeFakePi("fail");
      const snapshot = yield* checkPiProviderStatus(
        decodePiSettings({ enabled: true, binaryPath }),
      );

      // Pi's catalogue IS the auth signal, so an empty one reads as "signed
      // out" — but only when the listing actually ran. A failed probe says
      // nothing about auth, and telling a signed-in user to sign in because
      // their network was slow sends them round a pointless loop.
      expect(snapshot.installed).toBe(true);
      expect(snapshot.version).toBe("0.85.1");
      expect(snapshot.auth.status).toBe("unknown");
      expect(snapshot.message).not.toMatch(/sign in/i);
    }),
  );

  it.effect("reports unauthenticated only when the listing succeeded and was empty", () =>
    Effect.gen(function* () {
      const binaryPath = yield* makeFakePi("empty");
      const snapshot = yield* checkPiProviderStatus(
        decodePiSettings({ enabled: true, binaryPath }),
      );

      expect(snapshot.auth.status).toBe("unauthenticated");
      expect(snapshot.message).toMatch(/sign in/i);
    }),
  );
});
