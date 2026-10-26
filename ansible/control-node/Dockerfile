FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
# Apt versions are deliberately unpinned: pins break on Debian security updates; the lab rebuilds images on each run.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    ansible openssh-client python3 \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -m 0700 /root/.ssh
WORKDIR /ansible
ENV ANSIBLE_LOCAL_TEMP=/tmp/ansible-local
CMD ["sleep", "infinity"]
