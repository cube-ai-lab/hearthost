# Publishing Hearthost

Official remote: `git@github.com:cube-ai-lab/hearthost.git`

Suggested GitHub metadata:

- Description: `CLI-first multi-tenant WordPress and Laravel hosting for Ubuntu. Per-user RAM/CPU limits, per-site PHP versions, no control panel.`
- Topics: `nginx`, `php-fpm`, `wordpress`, `laravel`, `multi-tenant`, `hosting`, `cgroup`, `ubuntu`
- License: MIT (see `LICENSE`)

Never commit:

- Public IPs, PTR hostnames, or a specific VPS hardware inventory
- `/etc/hearthost/hearthost.conf`, user YAML, TLS keys, or database passwords

`.gitignore` already excludes local config overlays.
