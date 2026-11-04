# Plan 2c (fixture)

## Dependency Map

| Task | Depends On | Level |
|------|-----------|-------|
| Task 0: MINOR de 2b (2b-1 plazo de la pausa con `set-params`, 2b-2 pausa y detener durante el backoff), solo E2E | none | 0 |
| Task 1: Servidor: acciones `answer`, `retry` y `open` en `control_channel.py` | none | 0 |
| Task 2: Módulos del driver: órdenes de 2c en `DriverControl.psm1`, espera genérica, bloque `awaiting`, prompts de respuesta, costo de la corrida; `DriverOpen.psm1` nuevo (A6); aviso `AWAITING` en `DriverNotify.psm1` | none | 0 |
| Task 3: Cableado del driver: `AWAITING`, tope de costo, A1, A4, A6 y aviso D5 en espera | Task 0, Task 2 | 1 |
| Task 4: Página: `AWAITING`, Responder, Reintentar, Abrir, cuenta regresiva, aviso del navegador y costo de esta corrida | Task 1 | 1 |

**Parallel groups:**
- **Level 0 (parallel):** Task 0, Task 1, Task 2. Archivos disjuntos (ver «Puntos calientes»).
- **Level 1 (parallel):** Task 3, Task 4. Task 3 consume las funciones de Task 2 y edita `tests/PlanSessionDriver.Tests.ps1`, que Task 0 tocó (dependencia de archivo: los dos cambian `Invoke-FakeDriverRun`). Task 4 prueba la página contra el `server.py` con las acciones de Task 1. Task 3 y Task 4 no comparten archivos.

**Puntos calientes (L9):**

| Archivo | Tarea (nivel) |
|---|---|
| `scripts/plan-session-driver.ps1` | T3 (1). T0 (0) solo si uno de sus tests revela un defecto (ver T0) |
| `assets/dashboard.html` | T4 (1) |
| `scripts/modules/DriverStatus.psm1` | ninguna (2b ya trae `Set-DriverStatusLiveState` con `AWAITING`) |
| `scripts/modules/HttpDashboard.psm1` | ninguna (A6 la ejecuta el driver, DO-6) |
| `tests/PlanSessionDriver.Tests.ps1` | T0 (0), T3 (1) |
| `tests/Dashboard.Tests.ps1` | T4 (1) |

El resto de archivos son disjuntos: T1 `scripts/dashboard/control_channel.py`, `tests/python/test_control_channel.py`, `tests/python/test_server_control.py`; T2 `scripts/modules/DriverControl.psm1`, `scripts/modules/DriverOpen.psm1` (nuevo), `scripts/modules/DriverNotify.psm1`, `tests/DriverControl.Tests.ps1`, `tests/DriverOpen.Tests.ps1` (nuevo), `tests/DriverNotify.Tests.ps1`.

## File Structure

| Archivo | Tarea | Orden |
|---|---|---|
| `scripts/otro.ps1` | Task 9 | 7 |
| `tests/otro.Tests.ps1` | Task 9 | 8 |
