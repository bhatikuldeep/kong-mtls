# Kong mTLS: authenticate API clients with certificates

Client apps authenticate to an API with a client certificate. Kong Gateway checks the certificate and either accepts the call, as a known consumer, or rejects it. As a bonus, that consumer then works with the ACL plugin and with plugins that can be scoped to a consumer: here, gold, silver and bronze rate limits and a route only gold can call.

It uses the mTLS Auth plugin, an Enterprise plugin that Konnect includes, on Kong Gateway in Konnect hybrid mode with the data plane in Docker. This is mTLS between client apps and Kong; the data plane's own mTLS link to the control plane is separate. Walkthrough: [Kong mTLS Part 1: authenticate API clients with certificates](https://kuldeepbhati.com/posts/kong-mtls-client-certificate-authentication/).

| Caller | Certificate | Result |
|---|---|---|
| client-a, client-b, client-c | from the client CA, mapped to a consumer | `200`, and the backend sees which consumer called |
| client-d | from the client CA, no consumer | `401` |
| anyone | self-signed, or none | `401` |

Bonus: client-a is gold (10 calls per minute), client-b silver (5), client-c bronze (3, then `429`). Only gold can call `/reports`; the others get `403`.

## How it works

**Set up once.** A client CA signs a certificate for each client app, and the app keeps its private key. Kong holds the CA certificate (no key) and one consumer per client app, mapped to the name on its certificate by an mTLS credential pinned to that CA. `consumer_by: []` turns off matching by consumer `username` or `custom_id`, which would bypass the pin. The backend needs no changes.

**On every call:**

1. **TLS handshake.** Kong sends its own certificate and asks for the client's. The client app proves with its private key that its certificate is its own.
2. **Authentication (mTLS Auth).** Was the certificate signed by the client CA, and is it in date? Does a consumer match a name on it? Kong tries every SAN, then the CN. No to either: `401`.
3. **Plugins that use the consumer**, in plugin priority order: the ACL (`403`), then the tier's rate limit (`429`).
4. **The backend** gets the call with `X-Consumer-Username`, `X-Consumer-Custom-Id` and `X-Consumer-Id`. Kong replaces any copies the client app sent.

## Prerequisites

- Docker
- [mise](https://mise.jdx.dev): `mise install` installs the pinned `kongctl`, `deck` and `jq`
- `openssl` and `curl`
- A Konnect account and a [personal access token](https://cloud.konghq.com/global/account/tokens). `make up` creates a control plane named `mtls-identity`, and `make clean` deletes it.

| Component | Version |
|---|---|
| Kong Gateway (`kong/kong-gateway`) | 3.16.0.2, pinned by digest in `compose.yaml` |
| go-httpbin (echo backend) | 2.26.0 |
| kongctl | 1.28.1 |
| decK | 1.70.1 |

## Step 1: Start the lab

Run every command from the repository root.

```bash
git clone https://github.com/bhatikuldeep/kong-mtls
cd kong-mtls
mise install
eval "$(mise activate bash)"   # or zsh: so make uses the pinned tools
cp .env.example .env           # set KONNECT_TOKEN, and KONNECT_REGION if not eu
make up                        # certificates, Konnect control plane, data plane
```

`KONNECT_REGION` is the region of your Konnect organization: `eu`, `us`, `au`, `me`, `in` or `sg`. `make up` waits until the data plane has loaded the configuration from Konnect, then prints `Ready: run 'make test'`. The backend is an echo service that returns the headers it received. In Konnect, the `mtls-identity` control plane shows the consumers, consumer groups and plugins.

## Step 2: Check the certificates

`make up` created them in `certs/` with `scripts/certs.sh`. Check them the way Kong checks the chain:

```bash
openssl verify -CAfile certs/client-ca.crt certs/client-a.crt certs/rogue.crt
```

`client-a.crt` is `OK`. `rogue.crt` claims to be client-a but is self-signed, so it fails.

## Step 3: Read the Kong configuration

Two decK files: `kong/certs.yaml` (generated) holds the client CA certificate and the gateway's server certificate. `kong/kong.yaml` holds the mTLS Auth plugin (`ca_certificates`, `ssl_verify: true`, `consumer_by: []`), the routes (`https` with `snis`), the consumers with their mTLS credentials, and the consumer groups with their rate limits (`window_type: fixed`, so counters reset each minute).

## Step 4: Test it

```bash
api() { curl -s --resolve api.example.test:8443:127.0.0.1 \
  --cacert certs/gateway-ca.crt "$@"; }
u=https://api.example.test:8443

api -i --cert certs/client-a.crt --key certs/client-a.key $u/orders
```

`api.example.test` isn't a real hostname: `--resolve` points it at 127.0.0.1, and `--cacert` trusts the server certificate `make up` created. The route only matches that SNI. With a different `GATEWAY_PORT` in `.env`, replace 8443 in both places.

Then the calls that fail (no certificate, `rogue`, and client-d with no consumer), all `401`:

```bash
s=' %{http_code}\n'
api -w "$s" $u/orders
api -w "$s" --cert certs/rogue.crt --key certs/rogue.key $u/orders
api -w "$s" --cert certs/client-d.crt --key certs/client-d.key $u/orders
```

Then every check, the bonus included. It ends with `19 passed, 0 failed`:

```bash
make test
```

## Step 5 (bonus): Use the consumer in other plugins

Every call now carries a consumer, so the ACL plugin and plugins scoped to a consumer or consumer group work for certificate clients too (see the [supported scopes table](https://developer.konghq.com/gateway/entities/plugin/#supported-scopes-by-plugin)). This repository has two examples in `kong/kong.yaml`:

- **Tiers:** consumer groups `gold`, `silver` and `bronze`, each with a Rate Limiting Advanced plugin (`identifier: consumer`, 10, 5 and 3 calls per minute). Client-c is bronze. `make test` used up its three calls, so wait a minute; then the fourth call in a row gets `429`:

  ```bash
  for i in 1 2 3 4; do
    api -o /dev/null -w '%{http_code}\n' \
      --cert certs/client-c.crt --key certs/client-c.key $u/orders
  done
  ```

- **A route only gold can call:** an ACL on `/reports` with `allow: [gold]` and `include_consumer_groups: true`. Client-b is silver, so it gets `403`. Gold gets through, and the backend sees `X-Consumer-Groups: gold`:

  ```bash
  api -w "$s" --cert certs/client-b.crt --key certs/client-b.key $u/reports
  api --cert certs/client-a.crt --key certs/client-a.key $u/reports \
    | jq '.headers["X-Consumer-Groups"]'
  ```

## Step 6: Clean up

```bash
make down    # remove the containers, keep Konnect and the certificates
make clean   # also delete the Konnect control plane and the certificates
```

## Use it for your own API

1. **Choose the client CA.** Recommended: the API team runs it, and each client app sends a CSR. If the client's organisation runs its own CA, it shares the CA certificate (never the key). Kong needs the certificate with `CA:TRUE`. Trust only CAs that control both the SAN and the CN they issue. If an intermediate CA signs the client certificates, upload the root and have client apps send the intermediate with their certificate, or upload the intermediate and set `allow_partial_chain: true`; `ca_certificate` pins point to the CA certificate you uploaded. Here, replace `client-ca.crt` in `kong/certs.yaml` (keep the ID).
2. **Add mTLS Auth** to the service or route: `ca_certificates`, `ssl_verify: true`, `consumer_by: []`, and every route with `protocols: [https]` and its `snis`. For revocation, the default `revocation_check_mode`, `IGNORE_CA_ERROR`, checks the CRL or OCSP responder a certificate names and lets the call through if that check can't complete; `STRICT` rejects the call instead, so every client gets `401` while the responder is down. Here, point the `orders-api` service `url` at your backend.
3. **Create one consumer per client app**, with an `mtls_auth_credentials` entry: `subject_name` is the name on the certificate, and `ca_certificate` pins it to its CA. mTLS Auth never creates consumers.
4. **Issue the certificates.** The CA signs each CSR with the name in the SAN. Use short validity with automated renewal, and keep the CA key off the gateway. A renewed certificate with the same name keeps working. To cut one client off at once, delete its mTLS credential in Konnect: `make up` only creates and updates, so removing it from `kong/kong.yaml` alone doesn't delete it.
5. **Test three cases:** a mapped certificate gets `200`, and no certificate or an unmapped one gets `401`.
6. **Add consumer-based plugins** as needed. Rate limit counters with `strategy: local` are per node, so three data plane nodes allow three times the limit. `strategy: redis` gives one shared counter, exact with `sync_rate: 0`; `cluster` isn't available in hybrid mode or Konnect.

Watch out for:

- **TLS must end at Kong.** An L7 load balancer in front ends TLS, so Kong never sees the certificate. Use TCP passthrough, or have the edge forward the certificate to the [Header Cert Auth plugin](https://developer.konghq.com/plugins/header-cert-auth/), and make sure only the edge can reach Kong, so no one else can send that header.
- **The gateway's server key** is in `kong/certs.yaml` here. In production, keep it in a vault and reference it.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| The data plane logs `bad config received from control plane ... ssl_verify cannot be disabled` | From 3.14, `tls_certificate_verify` is `on` by default, and Konnect stores `ssl_verify: false` for `mtls-auth` if it isn't set. Set `ssl_verify: true` (it controls TLS verification of the CRL and OCSP endpoints). |
| A valid certificate gets `401 TLS certificate failed verification` | No consumer matches it; the answer is the same as for an untrusted certificate. The data plane log says `certificate is valid but consumer matching failed, using cn = ...`. Check the `subject_name` mappings. |
| Konnect rejects the CA certificate | It must have the `CA:TRUE` basic constraint. |
| Clients of other APIs on the same gateway are asked for a certificate | A route that mTLS Auth applies to without `snis` makes Kong ask for a client certificate in every TLS handshake. Set `snis` on every such route. |
| A gold client gets `403` on `/reports` | The ACL reads consumer groups only with `include_consumer_groups: true`. |
| A consumer or credential removed from `kong/kong.yaml` still works | `make up` only creates and updates. Delete it in Konnect, or run `make clean` and `make up`. `make test` shows the leftover as drift. |

## Files

| File | What it does |
|---|---|
| `kong/kong.yaml` | The gateway configuration (decK): consumers, consumer groups, the service, routes and plugins |
| `kong/certs.yaml` | Generated by `scripts/certs.sh`: the client CA certificate (no key) and the gateway's server certificate |
| `konnect/control-plane.yaml` | The Konnect control plane and the data plane certificate (kongctl), which also runs decK for the two files above |
| `compose.yaml` | The data plane and the echo backend |
| `scripts/certs.sh` | The client CA, four client certificates, a self-signed rogue one, the gateway's certificate and the data plane's |

## Licence

MIT. A personal project, not official Kong documentation.
