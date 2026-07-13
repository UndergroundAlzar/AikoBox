# Self-use quick start (subscription only)

AikoBox is a Windows x64 client. If you only use **subscription links**, you do not need TUN, rule overrides, or advanced core settings.

## Safe first run

1. **Keep your current proxy software running** until AikoBox works. Do not uninstall your only working VPN/proxy first.
2. Download the **portable** build from the GitHub Release when available (or build locally). Prefer portable for testing.
3. Open AikoBox → **Profiles** → paste your **subscription URL** → import.
4. Wait until nodes appear. If import fails, read the error text (timeout, auth rejected, invalid URL, unsafe redirect). Fix the link or token; do not ignore opaque failures.
5. Turn on **System Proxy** (ordinary mode). **Do not enable TUN** on the first try.
6. Select a node / group and verify a normal website loads.
7. **Exit AikoBox** and confirm the system can still access the internet (proxy restored).

## Updating a subscription

- Use the profile refresh / “update all” action for remote profiles.
- A failed update keeps the **previous** working configuration when possible.
- Prefer “proxy” for update only after you already have a working subscription.

## What not to do first

- Do not enable TUN before system proxy works.
- Do not make AikoBox your only network path before exit/restore is proven.
- Do not paste subscription URLs into untrusted chat logs (they often contain tokens).

## Related in-app guide

The first-run tour covers the same path: import subscription → system proxy → select node.
