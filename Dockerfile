FROM python:3.12-alpine
# had a few errors with newer py+alpine; so be it

# Install build and dependencies and supervisor
# todo split steps, even though unsure if doing it won't break
# future development on container @ stage
RUN apk add --no-cache \
    # build-base \
    # gcc \
    bash \
    # musl-dev \
    ca-certificates \
    libxml2 \
    libxslt \
    libffi \
    nodejs \
    npm \
    # libffi-dev \
    # python3-dev \
    # libxml2-dev \
    # libxslt-dev \
    openssl \
    openssh-client \
    openssh-server \
    # openssl-dev \
    supervisor \
    nano \
    curl \
    vim \
    git \
    zsh

WORKDIR /app

COPY . /app/

# setup zsh
RUN curl -o /tmp/oh-my-zsh-installer.sh -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh && \
    ZSH=/usr/local/oh-my-zsh/ bash /tmp/oh-my-zsh-installer.sh "" --unattended && \
    mkdir -p /etc/zsh/zshrc.d/ && sed -i '/root\:/ s%/bin/sh%/bin/zsh%g' /etc/passwd
# core rc files
RUN cp docker_build/bashrc /root/.bashrc && \
    cp docker_build/vimrc /root/.vimrc && \
    cp docker_build/gitconfig /root/.gitconfig && \
    cp -a docker_build/zshrc.d/*.zsh /etc/zsh/zshrc.d && \
    cp docker_build/ssh_config /etc/ssh_config && \
    git remote -v | awk 'END { if ($0 ~ /http/) { split($2,r,"/"); sr="git@"r[3]":"r[4]"/"r[5]".git"; print "Switch from http to ssh "sr; system("git remote set-url origin "sr)}}'

# setup newrelic
RUN set -x; cd /tmp/ \
    && export NR_VER="1.65.4" \
    && wget -qO - "https://download.newrelic.com/infrastructure_agent/binaries/linux/amd64/newrelic-infra_linux_${NR_VER}_amd64.tar.gz" | tar xzf - \
    && cd newrelic-infra && cp -at / etc opt usr var || true \
    && cd .. && unset NR_VER
#    && echo -e 'license_key: {{NEW_RELIC_LICENSE_KEY}}\nlogs:\n  enabled: false' > /etc/newrelic-infra.yml

# setup newrelic-python-agent
RUN cd /tmp/ && export NR_PY_VER="10.15.0" \
    && pip install "newrelic[distributed_tracing]==${NR_PY_VER}" \
    && unset NR_PY_VER

RUN pip install --upgrade pip && \
    pip install gunicorn && \
    cd /app && pip install -r requirements.txt && chmod +x entrypoint.sh

# RUN cd frontend && npm install && npm run build

RUN mv supervisord.conf /etc/supervisord.conf
EXPOSE 8000

CMD ["/app/entrypoint.sh"]
# dbg 🐞 🍩
# CMD ["sh","-c","sleep infitiy"]
