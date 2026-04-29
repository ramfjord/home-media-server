# Fixture certificates — throwaway

The `fullchain.pem` / `privkey.pem` files in this directory are
**self-signed throwaway certs** generated solely so that the
fixture `Caddyfile.elp` template has real cert paths to reference
during golden-test renders.

- Subject: `CN=fx-fixture-do-not-use`
- Key: never used by any production service.
- These files are not rendered through the renderer. The goldens
  reference cert *paths* (strings), not cert bytes.

**Do not reuse these certs for anything real.** They have no value;
the private key is checked into the public repo. Anyone can read it.

## Regenerating

If Caddy ever requires a different cert format and the templates
break, regenerate from this directory:

```sh
openssl req -x509 -newkey rsa:2048 \
  -keyout privkey.pem -out fullchain.pem \
  -days 36500 -nodes \
  -subj "/CN=fx-fixture-do-not-use"
```

The `-days 36500` (~100 years) avoids expiry-driven test churn.
