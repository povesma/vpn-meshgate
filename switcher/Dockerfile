FROM alpine:3.21
RUN apk add --no-cache curl docker-cli docker-cli-compose
COPY switcher.sh /switcher.sh
RUN chmod +x /switcher.sh
CMD ["/switcher.sh"]
