FROM alpine:3.21

RUN apk add --no-cache curl iputils-ping bind-tools docker-cli jq

COPY bot.sh /bot.sh
RUN chmod +x /bot.sh

CMD ["/bot.sh"]
