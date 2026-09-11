# Third-party notices

agy-bridge remains based primarily on the MIT-licensed upstream project by
AlvaroTapia-f. This fork also cleanly reimplements two design ideas; no source
code from the projects below was copied verbatim into the TypeScript
implementation.

## agy-openai-shim

- Repository: https://github.com/tphakala/agy-openai-shim
- License: MIT
- Credit: inspiration for creating an empty, per-request working directory and
  cleaning it after each invocation.

## agy2api

- Repository: https://github.com/truongqv12/agy2api
- License: MIT
- Credit: inspiration for turning OpenAI-compatible data-URI content into
  temporary local attachments before invoking the model CLI.

The implementation in this fork adds its own validation, MIME allowlist, byte
limits, lifecycle handling, and integration with agy-bridge's existing real
`stream-json` and tool-call paths.
