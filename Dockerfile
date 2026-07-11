# ========================================================
# Stage: Builder
# ========================================================
FROM golang:1.26-alpine AS builder
WORKDIR /app
ARG TARGETARCH
ARG TARGETVARIANT

RUN apk --no-cache --update add \
  build-base \
  gcc \
  curl \
  unzip

COPY . .

ENV CGO_ENABLED=1
ENV CGO_CFLAGS="-D_LARGEFILE64_SOURCE"
RUN go build -ldflags "-w -s" -o build/x-ui main.go
RUN chmod +x ./DockerInit.sh \
  && EFFECTIVE_ARCH="${TARGETARCH:-amd64}" \
  && INIT_ARCH="$EFFECTIVE_ARCH" \
  && if [ "$EFFECTIVE_ARCH" = "arm" ] && [ "${TARGETVARIANT:-v7}" = "v6" ]; then INIT_ARCH=armv6; fi \
  && ./DockerInit.sh "$INIT_ARCH" \
  && test -x "/app/build/bin/xray-linux-${EFFECTIVE_ARCH}" \
  && test -s /app/build/bin/geoip.dat \
  && test -s /app/build/bin/geosite.dat

# ========================================================
# Stage: Final Image of X-MILI
# ========================================================
FROM alpine
ENV TZ=Asia/Tehran
WORKDIR /app

RUN apk add --no-cache --update \
  ca-certificates \
  tzdata \
  fail2ban \
  bash \
  curl \
  iproute2 \
  openvpn \
  openssl \
  socat

COPY --from=builder /app/build/ /app/
COPY --from=builder /app/DockerEntrypoint.sh /app/
COPY --from=builder /app/x-ui.sh /usr/bin/x-ui
COPY --from=builder /app/x-ui.sh /usr/bin/ml


# Configure fail2ban
RUN rm -f /etc/fail2ban/jail.d/alpine-ssh.conf \
  && cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local \
  && sed -i "s/^\[ssh\]$/&\nenabled = false/" /etc/fail2ban/jail.local \
  && sed -i "s/^\[sshd\]$/&\nenabled = false/" /etc/fail2ban/jail.local \
  && sed -i "s/#allowipv6 = auto/allowipv6 = auto/g" /etc/fail2ban/fail2ban.conf

RUN chmod +x \
  /app/DockerEntrypoint.sh \
  /app/x-ui \
  /usr/bin/x-ui \
  /usr/bin/ml

ENV XUI_ENABLE_FAIL2BAN="false"
EXPOSE 2053
VOLUME [ "/etc/x-ui" ]
CMD [ "./x-ui" ]
ENTRYPOINT [ "/app/DockerEntrypoint.sh" ]
