FROM alpine:3.21

RUN apk add --no-cache dnsmasq bind-tools iproute2 jq curl

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
