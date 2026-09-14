import * as Effect from "effect/Effect";
import { TextGenerationError } from "@t3tools/contracts";

import type * as TextGeneration from "./TextGeneration.ts";

const unsupported = (operation: string) =>
  Effect.fail(
    new TextGenerationError({
      operation,
      detail: "Oh My Pi does not support text generation in this build.",
    }),
  );

export const makeOmpTextGeneration = Effect.succeed({
  generateCommitMessage: () => unsupported("generateCommitMessage"),
  generatePrContent: () => unsupported("generatePrContent"),
  generateBranchName: () => unsupported("generateBranchName"),
  generateThreadTitle: () => unsupported("generateThreadTitle"),
} satisfies TextGeneration.TextGeneration["Service"]);
