FROM alpine:3.21

RUN apk add --no-cache \
    strongswan \
    xl2tpd \
    ppp \
    iproute2 \
    iptables \
    iputils-ping \
    curl \
    bind-tools \
    && mkdir -p /var/run/xl2tpd \
    && touch /var/run/xl2tpd/l2tp-control

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
