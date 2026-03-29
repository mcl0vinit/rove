FROM ghcr.io/nixos/nix:latest

ENV PATH=/nix/var/nix/profiles/default/bin:/root/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin

WORKDIR /opt/rove-devbox

COPY flake.nix flake.lock ./

RUN mkdir -p /etc/nix \
    && printf '%s\n' \
      'experimental-features = nix-command flakes' \
      'accept-flake-config = true' \
      > /etc/nix/nix.conf \
    && nix --extra-experimental-features 'nix-command flakes' profile add --priority 4 --accept-flake-config .#default \
    && nix store gc

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod 755 /usr/local/bin/entrypoint.sh \
    && mkdir -p /etc/ssh /persist /root/.ssh /var/run/sshd /workspace

WORKDIR /workspace

EXPOSE 2222

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
