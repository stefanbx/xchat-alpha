# ӾChat node front (Cloudflare Worker)

A stable, short, free `workers.dev` hostname that reverse-proxies to a home node whose public URL
churns (a Cloudflare quick tunnel). The current backend origin lives in KV key `backend`, refreshed by
the home machine on each restart. Announce the **worker URL** on the XNO ledger (short + stable); the
worker forwards to wherever the node lives now.

Deploy: `npx wrangler kv namespace create BACKEND_KV` → put id in `wrangler.toml` → `npx wrangler deploy`.
Point it at a backend: `npx wrangler kv key put --remote --namespace-id=<id> backend https://<node-url>`
(the `--remote` flag is required — wrangler v4 writes KV locally by default).
