FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

ARG DOTFILES_REPO=https://github.com/mcl0vinit/dotfiles.git
ARG DOTFILES_REF=ad9fd4d4429b8bc08d9cf0a6dfa69aa79ecc6be5

SHELL ["/bin/bash", "-lc"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      openssh-client \
      openssh-server \
      sudo \
      xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 rove \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash rove \
    && mkdir -p /nix /persist /workspace /var/run/sshd /etc/sudoers.d \
    && chown rove:rove /nix /persist /workspace \
    && printf 'rove ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/rove \
    && chmod 440 /etc/sudoers.d/rove

USER rove
ENV USER=rove
ENV HOME=/home/rove
ENV PATH=/home/rove/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin

WORKDIR /opt/rove-devbox

COPY --chown=rove:rove flake.nix flake.lock ./

RUN mkdir -p "$HOME/.config/nix" "$HOME/.local/share/rove" \
    && printf '%s\n' \
      'experimental-features = nix-command flakes' \
      'accept-flake-config = true' \
      > "$HOME/.config/nix/nix.conf" \
    && curl -fsSL https://nixos.org/nix/install -o /tmp/install-nix \
    && sh /tmp/install-nix --no-daemon --yes \
    && rm -f /tmp/install-nix \
    && . "$HOME/.nix-profile/etc/profile.d/nix.sh" \
    && nix build --accept-flake-config .#default \
    && ln -sfn "$(readlink -f result)" "$HOME/.local/share/rove/devbox-profile" \
    && rm -f result \
    && export PATH="$HOME/.local/share/rove/devbox-profile/bin:$HOME/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin" \
    && dotfiles_dir="$HOME/.dotfiles" \
    && rm -rf "$dotfiles_dir" \
    && git init "$dotfiles_dir" >/dev/null \
    && git -C "$dotfiles_dir" remote add origin "$DOTFILES_REPO" \
    && git -C "$dotfiles_dir" fetch --depth 1 origin "$DOTFILES_REF" \
    && git -C "$dotfiles_dir" checkout --force FETCH_HEAD >/dev/null \
    && DOTFILES_DIR="$dotfiles_dir" "$dotfiles_dir/bin/bootstrap" --apply

LABEL rove.dotfiles.repo=$DOTFILES_REPO
LABEL rove.dotfiles.ref=$DOTFILES_REF

USER root
ENV PATH=/home/rove/.local/share/rove/devbox-profile/bin:/home/rove/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod 755 /usr/local/bin/entrypoint.sh \
    && mkdir -p /etc/profile.d /home/rove/.ssh \
    && chmod 700 /home/rove/.ssh \
    && chown -R rove:rove /home/rove/.ssh /persist /workspace \
    && printf '%s\n' \
      'export PATH="$HOME/.local/share/rove/devbox-profile/bin:$HOME/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin"' \
      > /etc/profile.d/rove-devbox-path.sh \
    && chmod 644 /etc/profile.d/rove-devbox-path.sh \
    && for binary in /home/rove/.local/share/rove/devbox-profile/bin/* /home/rove/.nix-profile/bin/*; do \
         ln -sf "$binary" "/usr/local/bin/$(basename "$binary")"; \
       done

WORKDIR /workspace

EXPOSE 2222

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
