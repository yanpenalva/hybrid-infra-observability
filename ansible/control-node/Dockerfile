FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
# Apt versions are deliberately unpinned: pins break on Debian security updates; the lab rebuilds images on each run.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    ansible openssh-client python3 \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -m 0700 /root/.ssh
WORKDIR /ansible
ENV ANSIBLE_LOCAL_TEMP=/tmp/ansible-local
CMD ["sleep", "infinity"]
