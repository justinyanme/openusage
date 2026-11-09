# Kimi Code usage API

Checked on 2026-11-06. This is an integration research note, not a promise of a stable public API.
No request using a real account credential was made during this research.

The HTTP client and mapper are implemented under `Providers/Kimi/`, with OAuth and API-key sign-in,
dashboard metrics, and command-line resources. The confirmed default order is Session, Weekly,
Monthly; absent windows stay hidden. Fixtures cover parsing, sign-in, refresh errors, and exports.

## Scope

Kimi Code subscription quota is available from the endpoint used by Kimi's own clients. This is
separate from Moonshot's prepaid model API balance. The response describes shared account quota,
not token counts or charges broken down by model.
[Official quota client](https://github.com/MoonshotAI/kimi-code/blob/480019652d029623fa31133cfa613adf9afa1417/packages/oauth/src/managed-usage.ts).

New subscriptions have a rolling five-hour window and a monthly total; legacy subscriptions also
have a weekly window. Devices and API keys share the account's quota. The monthly total covers
Kimi membership usage as well as coding.
[Membership benefits](https://www.kimi.com/en/help/kimi-code/benefits).

## Request and sign-in

```http
GET https://api.kimi.com/coding/v1/usages
Authorization: Bearer <Kimi Code OAuth access token or user-provided API key>
Accept: application/json
```

The current official client defines that URL and sends a bearer token. It also defines a global
endpoint at `https://api.kimi.ai/coding/v1/usages`; regional selection needs separate validation.
[Current HTTP implementation](https://github.com/MoonshotAI/kimi-code/blob/480019652d029623fa31133cfa613adf9afa1417/packages/oauth/src/managed-usage.ts).

### Device-code OAuth

Kimi's official client implements the device authorization grant:

- `POST https://auth.kimi.com/api/oauth/device_authorization`, form field `client_id`.
- Open the returned `verification_uri_complete` and show `user_code`.
- Poll `POST https://auth.kimi.com/api/oauth/token` with `client_id`, `device_code`, and
  `grant_type=urn:ietf:params:oauth:grant-type:device_code`.
- Renew at the same token endpoint with `grant_type=refresh_token` and `refresh_token`.

The public client ID is `17e5f671-d194-4dfb-9706-5516cb48c098`; no client secret or scope is sent.
The token response includes access and refresh tokens and `expires_in`. These are implementation
details of Kimi's client, not a separately registered OpenUsage OAuth client.
[Official flow](https://github.com/MoonshotAI/kimi-code/blob/480019652d029623fa31133cfa613adf9afa1417/packages/oauth/src/oauth.ts),
[Client configuration](https://github.com/MoonshotAI/kimi-code/blob/480019652d029623fa31133cfa613adf9afa1417/packages/oauth/src/constants.ts).

OpenUsage reads `/coding/v1/me` after authorization to obtain `user_id` for duplicate detection,
and email or nickname for the account name, then validates its quota. It saves tokens only in its
own Keychain, uses its own User-Agent, renews through the account runtime, and retries an unauthorized
quota read once. Existing API-key accounts retain their authentication method.
[Official profile client](https://github.com/MoonshotAI/kimi-code/blob/480019652d029623fa31133cfa613adf9afa1417/packages/oauth/src/managed-userinfo.ts).

### API key

There is first-party implementation evidence for API-key authentication: the older CLI's usage
command passes its configured key through `resolve_api_key`, which returns the configured key
when OAuth is absent, then sends it as the bearer credential.
[Usage command](https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/ui/shell/usage.py),
[Credential resolution](https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/auth/oauth.py#L848).

Users can create a key in the [Kimi Code Console](https://www.kimi.com/code/console) and use
OpenUsage's API-key sign-in. Official third-party setup documentation describes
creating and supplying these keys.
[Official OpenCode setup](https://www.kimi.com/code/docs/en/third-party-tools/opencode.html#configure-api-key).

A public issue asks for a supported third-party quota-display contract and polling guidance; it
had no maintainer answer when checked. The source proves an implementation exists, not a
documented compatibility guarantee. Actual API-key access still needs testing with a user-added
account. OpenUsage should use its own client identity and only its own stored credential.
[Contract question](https://github.com/MoonshotAI/kimi-code/issues/2937).

## Response fields

The current wire response has an optional `usages` entry for each window:

| Field | Meaning | Mapping |
|---|---|---|
| `usages.limit_5h` | Five-hour quota | Session |
| `usages.limit_7d` | Weekly quota | Weekly, when present |
| `usages.limit_month_total` | Shared monthly total | Monthly, when present |
| `usages.limit_month_code` | Coding's portion of the monthly total | A breakdown, not another limit |

Each entry carries `used_ratio` as a finite number or numeric string and optional `reset_time`
as an ISO timestamp. Multiply the ratio by 100 to display percent used.
[Official parser](https://github.com/MoonshotAI/kimi-code/blob/480019652d029623fa31133cfa613adf9afa1417/packages/oauth/src/managed-usage.ts),
[Monthly breakdown](https://github.com/MoonshotAI/kimi-code/blob/480019652d029623fa31133cfa613adf9afa1417/apps/kimi-code/src/utils/usage/usage-format.ts).

Window presence is authoritative. The official migration deliberately renders whichever windows
exist instead of branching on `goods_version`. A modern response without `limit_7d` must not gain
a Weekly row from a legacy field left alongside it.
[Quota-model migration](https://github.com/MoonshotAI/kimi-code/pull/3787).

Older responses use `usage` for the weekly summary and `limits[]` for additional windows. Counters
are `limit` and `used`, or `limit` and `remaining`; reset time is `resetTime`. Identify a five-hour
entry by its `window.duration` and `window.timeUnit`, such as 300 and `TIME_UNIT_MINUTE`, not its
array position. The official old parser supports numeric strings.
[Legacy parser](https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/ui/shell/usage.py).

## Compatibility and validation

Users reported stale zero ratios alongside nonzero legacy counters in the same response. One
report includes an exhausted weekly counter and a corresponding model-request refusal; another
includes the same defect for a new plan's five-hour counter. These are user observations, not a
maintainer-specified precedence rule.
[Weekly report](https://github.com/MoonshotAI/kimi-code/issues/3951),
[Five-hour and regional reports](https://github.com/MoonshotAI/kimi-code/issues/3908).

Implemented handling, inferred from those reports:

- In modern responses, keep the windows selected by `usages`. Use legacy counters only for a
  corresponding Session or Weekly window whose reset agrees within two seconds. The published
  examples differ by roughly 1–1.5 seconds, so exact timestamp equality misses them. The tolerance
  is an integration choice, not a documented Kimi guarantee.
- With no modern `usages`, support the legacy weekly summary and identified five-hour bucket.
- Reject malformed, boolean, negative, or non-finite measurements. Require an actual `used` or
  `remaining` counter; absent counters must not silently become zero.
- Preserve the reported reset. Do not invent a monthly cycle duration from its end date.
- Do not infer a plan name, model-specific token counts, or dollar spend from quota percentages.
- Keep malformed responses and failed HTTP requests visible as account errors. A missing optional
  window is different from a malformed reported window.

These choices should have focused fixtures for modern, legacy, mixed, empty, and malformed
responses. Compare a live user-added account against its console before claiming end-to-end
verification. The global endpoint, monthly coding breakdown, and booster wallet are separate
follow-ups; they are not needed to display the account's main quota windows.

## Icon

The official repository includes a small, self-contained monochrome SVG at
`apps/vscode/resources/kimi-icon.svg`. Its repository carries the MIT license with Moonshot AI's
2026 copyright notice; preserve that notice and license when copying the asset.
[Icon source](https://github.com/MoonshotAI/kimi-code/blob/480019652d029623fa31133cfa613adf9afa1417/apps/vscode/resources/kimi-icon.svg),
[License](https://github.com/MoonshotAI/kimi-code/blob/480019652d029623fa31133cfa613adf9afa1417/LICENSE).
