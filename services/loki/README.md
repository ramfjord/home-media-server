# Loki

Log aggregation backend, queried through Grafana. Alloy ships
journald log lines here from every systemd unit on the host, so logs
across services can be searched and correlated in one place rather
than ssh-ing in to `journalctl` per unit.

`loki.yml` is the storage and retention config.

## More

- Upstream: <https://github.com/grafana/loki>
- Docs: <https://grafana.com/docs/loki/latest/>
