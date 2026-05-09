# prometheus

Prometheus scrapes everything directly. Scrape configs are split out into
`scrape_configs/*.yaml.elp`, loaded via the main config's `scrape_config_files`
glob. To add a target, mark a service `scrape_target: true` in its
`service.yml` — `scrape_configs/scrape_configs.yaml.elp` picks it up
automatically.

`rules/` and the alertmanager wiring also live here.
