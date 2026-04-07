FROM alpine:3.19

RUN apk add --no-cache openvpn iptables curl iproute2

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
