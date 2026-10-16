FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
# Apt versions are deliberately unpinned: pins break on Debian security updates; the lab rebuilds images on each run.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    ansible openssh-client python3 \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -m 0700 /root/.ssh
WORKDIR /ansible
ENV ANSIBLE_LOCAL_TEMP=/tmp/ansible-local
CMD ["sleep", "infinity"]
