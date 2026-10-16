FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ansible openssh-client python3 \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -m 0700 /root/.ssh
WORKDIR /ansible
ENV ANSIBLE_LOCAL_TEMP=/tmp/ansible-local
CMD ["sleep", "infinity"]
