# Data sources

Checked 9 September 2026. The collector is deliberately read-only.

## Codex

Starts the installed `codex app-server` over stdio, performs `initialize` / `initialized`, calls `account/rateLimits/read`, then terminates the process group. It never starts a thread or an inference turn, reads auth tokens directly, or consumes earned limit resets.

[Official Codex app-server documentation](https://developers.openai.com/codex/app-server) defines `usedPercent`, `windowDurationMins`, Unix-second `resetsAt` and the optional multi-bucket `rateLimitsByLimitId`. Window names come from the actual duration, including accounts with only a weekly primary window. Additional model limits remain separate.

## Claude

Reads the existing Claude Code OAuth credential from its `Claude Code-credentials` macOS Keychain item, with the CLI credential file as a fallback. Calls `GET https://api.anthropic.com/api/oauth/usage` with the existing bearer token and the client's OAuth beta header. This is an undocumented account interface.

`five_hour.utilization`, `seven_day.utilization` and available optional model windows are percentages. Reset timestamps are ISO 8601. Newer responses also carry a `limits` list whose entries have a `kind` (`session`, `weekly_all`, `weekly_scoped`), a `percent`, and a `scope` naming a model or surface; model-specific weekly caps such as Fable's appear only there. The collector merges both forms under `seven_day_<model>` identifiers, skips duplicates, and marks account-wide and per-model pools as main so they lead the dropdown and count for the menu bar's most-used value. Surface-scoped limits stay under additional allowances. Expired credentials require a login refresh through Claude Code; this app does not refresh them itself. Polling has a five-minute minimum and honors HTTP 429 backoff.

[Claude's documented status-line interface](https://code.claude.com/docs/en/statusline) also exposes subscription limits after model responses. This app does not change the user's status line or depend on a running conversation.

## Cursor

Opens Cursor's `User/globalStorage/state.vscdb` read-only and selects only `cursorAuth/accessToken` and `cursorAuth/stripeMembershipType`. Calls the read-only Connect RPC `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` with an empty request.

The installed Cursor app's `workbench.desktop.main.js` establishes the service method and the response schema. `planUsage.autoPercentUsed` and `apiPercentUsed` represent separate pools. `billingCycleStart` and `billingCycleEnd` are milliseconds since epoch; both are normalized to seconds and displayed as the billing cycle. Percentages are not reconstructed from token logs or combined into a single blended quota. The default menu summary shows the higher of the two main pool percentages; Settings can select an individual pool and show usage, remaining allowance or reset countdown.

[Cursor usage documentation](https://prod.cursor.com/help/models-and-usage/usage-limits) describes the Cursor-model and other-model pools and billing-cycle resets. The account RPC is not the public team Admin API and may change.

## Vast.ai

[Machines API](https://docs.vast.ai/api-reference/machines/show-machines): `GET /api/v0/machines/`, with `owner=me` and `include_offline=1`. Fields were checked against the authenticated web console: `current_rentals_running`, `current_rentals_resident`, `gpu_occupancy`, `listed_gpu_cost`, `earn_hour`, `verification`, GPU and machine identifiers. Running counts establish active rental status; occupancy establishes rented GPU count. `earn_hour` is the console's reported hourly average, not assumed to be an instantaneous contract price.

Daily earnings use the current console's `GET /api/v1/user/earnings/` with a UTC epoch-day filter and `group_by="day"`. The collector follows pagination. If that endpoint is unavailable to the key, it falls back to the documented [machine earnings endpoint](https://docs.vast.ai/api-reference/billing/show-earnings): `GET /api/v0/users/me/machine-earnings/` with `sday` and `eday`. The installed official Vast SDK confirms these parameters are days since epoch.

Only complete daily rows are summed. Missing individual days in a valid completed report are zero; a missing or malformed report is an error. Duplicate dates are rejected. The app keeps machine state available when earnings fail, labels that result Partial, and shows unavailable financial values as dashes.

Per-machine utilization uses the documented [machine earnings endpoint](https://docs.vast.ai/api-reference/billing/show-earnings) (`per_machine[].gpu_earn` over `sday`/`eday`), falling back to `GET /api/v1/user/earnings/` grouped by `machine_id`. Utilization is GPU revenue ÷ (listed GPU price × GPUs × hours), so it is an estimate that rentals priced below the listing lower. It is recomputed at most every five minutes; if both endpoints fail, machines simply show no ring and Settings shows the reason.

Browser session credentials are never read or stored.

## Exchange rates

With Euro selected, the collector reads `GET https://api.frankfurter.dev/v1/latest?base=USD&symbols=EUR`, the European Central Bank reference rate, without any credential, and caches it for twelve hours in `rates.json`. A stale cached rate is kept while the service is unreachable; without any rate, amounts stay in USD.

## Credential boundary

No credential is written to this repository, printed, included in command arguments or stored in the metrics cache. The app saves an explicitly entered Vast key in macOS Keychain and sends it to its collector over a private stdin pipe. Each token is sent only to its provider's fixed HTTPS endpoint. Redirects are disabled to avoid forwarding credentials. Error bodies and local-helper stderr are suppressed; errors shown in the UI are normalized.

This is a local, unsandboxed macOS app because it integrates with installed CLI processes and account stores. Python 3 is a runtime prerequisite. The app bundle is ad-hoc signed for local use; a distribution build would need a stable signing identity and notarization.

## Expanded dropdown metrics

The seven-day GPU/storage/network/SLA breakdown is accumulated from the same validated complete-day rows as the seven-day total; today and referrals are excluded. Its components reconcile to that total.

Host details also preserve `earn_day`, `gpu_max_cur_temp` (degrees Celsius), `reliability2` (fraction displayed as a percentage), `cpu_name`, `listed`, and the listed hourly GPU price. Unknown optional fields remain absent. The daily host figure is labeled as Vast-reported earnings; its backend window is not used to calculate the seven-day daily average. Resident container counts include running containers.

The four menu items have independent persistent settings and macOS autosave names for ordering. SVGs are bundled template images. The configuration design follows the independent categories and global/per-item controls in the [official iStat Menus guide](https://register.bjango.com/help/istatmenus7/welcome/).

## Earnings definitions

Vast reports USD. With Euro selected, amounts use the European Central Bank reference rate from api.frankfurter.dev, refreshed every 12 hours; while no rate is available they stay in USD.

| Metric | Definition |
| --- | --- |
| GPU rate · est. | Occupied GPUs × current listed hourly GPU price. Existing contracts and discounts may differ. Storage and network revenue are excluded from this estimate. |
| Today | Recorded rental earnings since 00:00 UTC, including GPU, storage, network and SLA adjustments. Referrals are excluded. |
| 7-day average | Total recorded rental earnings over the previous seven complete UTC days ÷ 7. Includes zero-earning days; excludes the incomplete current day. |
| Rented | Vast reports `current_rentals_running > 0`. Stored-only containers are displayed separately. |
| Utilization | GPU revenue earned in the ring period ÷ (listed GPU price × GPUs × hours in the period), capped at 100%. Today means today so far in UTC; 7 and 30 days mean the previous complete UTC days. Rentals priced below the listing lower it. |
| Power cost | Entered watts × 24 h × price per kWh, summed over machines. Net figures deduct it: today for the hours elapsed since 00:00 UTC, the rate per hour, and the 7-day average per day. The Earnings setting shows gross, net or both columns; the menu bar follows net only when Net is selected. |

These are revenue metrics; electricity, hardware, tax and payout costs are not deducted. Hovering a machine row shows Vast's reported hourly average separately from the current price estimate, plus the provider's daily earnings figure, listed price, GPU temperature, reliability and CPU when available. Resident container counts include running containers and must not be added to running counts. The chart covers the previous seven complete UTC days; its tooltip shows the GPU, storage and network split.

## Refresh and freshness

The ChatGPT item shows Codex subscription allowances using its documented app-server interface. Claude and Cursor use the account endpoints their clients use; these are not stable public APIs. They may require adapter updates when providers change them. Sign in again using each provider's own app when credentials expire; Information Bar does not rotate their tokens or send inference requests.

ChatGPT, Cursor and Vast refresh every minute by default, or every two minutes when configured in General. Claude refreshes at most once every five minutes, including manual refreshes (the two-minute schedule checks it every six minutes). Server backoff is respected; without a server hint, sign-in errors retry after a minute and other provider errors after five. Last successful metrics remain visible with a stale label if a refresh fails, and disappear from the menu bar summary. Cache files contain normalized metrics only and have mode `0600` under `~/Library/Application Support/Information Bar/Cache`.
