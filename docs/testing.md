# Testing

[← Volver al README](../README.md) · [Arquitectura](architecture.md) ·
[Contrato del modelo](model-contract.md) ·
[Internals del instalador](installer-internals.md)

## Suite

Suite verde con `deno task test`. El conteo cambia a medida que se agregan
regresiones; ejecutá el comando antes de citar un número concreto.

```sh
deno task test
```

La suite cubre el guard de `Host` (403), auth Bearer (401), ruteo y errores
400, streaming SSE, deadline-kill (502), salvage de transcript, retry de
sesión, hermeticidad del harness con `usage.jsonl` en `STATE_DIR` temporal, la
resolución de modelos en 3 niveles (`scripts/sync-models.ts`) y el fallback de
modelos.

Para el path bare/multimodal también verifica: workspace aislado por request,
`cwd` del hijo, staging de data URI con nombres generados y SHA-256, orden de
partes text/attachment, rechazo de URLs remotas y MIME/partes no soportados,
límites 413 por archivo/request, cleanup en buffered/SSE/disconnect, migración
segura del agente `raw`, `AGY_REUSE` con attachments y regresiones de
abort/deadline/stdin/concurrencia que podrían dejar un workspace vivo mientras
`agy` todavía corre.

Los tests de servicio usan un `agy` hermético. Después de instalar en una
máquina real, hacé además un smoke con el CLI oficial para confirmar el
comportamiento de su `view_file` con los tipos de archivo que vayas a usar.

Smoke test manual post-instalación (puente vivo, variante → wire id):
ver [Verificación](installer-internals.md#verificación), paso 5
(`POST auto-ro-*`).

## Diagnóstico

```sh
systemctl --user status agy-bridge
journalctl --user -u agy-bridge -f
tail ~/.local/state/agy-bridge/usage.jsonl
# Smoke test: ver Verificación paso 5 (POST auto-ro-*)
```

Si agy cambia flags/eventos (stream-json) o el comportamiento de `view_file`,
el bridge puede romper aunque el mock siga verde: revisar `agy --help`, correr
el smoke real, ajustar la integración y volver a ejecutar la suite.

## SDD

El flujo de desarrollo sigue Spec-Driven Development bajo `openspec/`; el
parche del TUI que mantiene verde `/sdd-model` con `agy-bridge` se documenta
en [Parche del TUI](installer-internals.md#parche-del-tui-gentle-ai-effort).
