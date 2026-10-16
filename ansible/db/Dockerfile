FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server python3 sudo supervisor prometheus-node-exporter stress-ng \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_* \
    && useradd -m -s /bin/bash ansible \
    && usermod -p '*' ansible \
    && echo 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ansible \
    && chmod 0440 /etc/sudoers.d/ansible
# EXCEPTION: unrestricted automation sudo only in disposable teaching nodes.
# APT and base tag are mutable; digest freezing is a known gap.
COPY managed-node/entrypoint.sh /usr/local/bin/hio-entrypoint
COPY managed-node/supervisord.conf /etc/supervisor/supervisord.conf
RUN chmod 0755 /usr/local/bin/hio-entrypoint
EXPOSE 22 9100
ENTRYPOINT ["/usr/local/bin/hio-entrypoint"]
