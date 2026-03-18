FROM alpine:3.21

RUN apk add --no-cache curl iputils-ping

COPY check.sh /check.sh
RUN chmod +x /check.sh

CMD ["/check.sh"]
