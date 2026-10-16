FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
# Apt versions are deliberately unpinned: pins break on Debian security updates; the lab rebuilds images on each run.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server python3 sudo supervisor prometheus-node-exporter stress-ng util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_* \
    && useradd -m -s /bin/bash ansible \
    && usermod -p '*' ansible \
    && echo 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ansible \
    && chmod 0440 /etc/sudoers.d/ansible \
    && useradd --system --no-create-home --shell /usr/sbin/nologin demo-app
COPY managed-node/entrypoint.sh /usr/local/bin/hio-entrypoint
COPY managed-node/supervisord.conf /etc/supervisor/supervisord.conf
COPY app/app.py /opt/demo-app/app.py
COPY app/supervisord-app.conf /etc/supervisor/conf.d/demo-app.conf
RUN printf '\n[include]\nfiles = /etc/supervisor/conf.d/*.conf\n' >> /etc/supervisor/supervisord.conf \
    && chmod 0755 /usr/local/bin/hio-entrypoint
EXPOSE 22 9100 8080
ENTRYPOINT ["/usr/local/bin/hio-entrypoint"]
